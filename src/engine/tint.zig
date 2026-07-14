//! Runtime tint + blink cue (issue #128; ADR 0033 phase 2): the engine-consumed half of
//! a content-declared `TintCue` — advance every cued entity's `TintCursor` from
//! WALL-CLOCK elapsed time (never a sim tick, exactly like `sprite.advance`) and resolve
//! which color, if any, overrides `Appearance.color`/the sprite tint this frame. Cosmetic
//! and hash-excluded: `advance` reads real elapsed time and the entity's EXISTING
//! (hashed) selector data component, and writes only the unhashed `TintCursor` column, so
//! it can never perturb `World.stateHash` (the physics/VFX invariant, CLAUDE.md).
//!
//! Lua triggers a state change through the EXISTING ADR 0024 named-data-component seam
//! (`mana.set(handle, selector, n)`) — no new scripting API. `n == 0` (or the selector
//! never written) means "no override"; `n` (1-based) selects `cue.states[n-1]`. This is
//! the "prefer data over Lua" split CLAUDE.md asks for: content declares WHAT each state
//! looks like (`TintCue.states`, ZON), a script decides WHEN to switch (an event sets the
//! selector), and the engine renders it every frame with no per-entity Lua callback.

const std = @import("std");
const components = @import("components.zig");
const World = @import("world.zig").World;

const TintCue = components.TintCue;

/// Advance every `TintCue` entity's `TintCursor` by `dt_s` WALL-CLOCK seconds: accumulate
/// the blink-phase clock, resolve the entity's selector data component (0/absent/
/// out-of-range ⇒ no override), and write the frame's display color — `null` (no
/// override) or the selected state's color, alternated with `blink_color` at `blink_hz`
/// (a wall-clock square wave) when the state declares one. `dt_s <= 0` does not advance
/// the blink phase (mirrors `sprite.advance`). Cosmetic: writes only the unhashed
/// `TintCursor` column, never sim state. Owns nothing.
pub fn advance(world: *World, dt_s: f32) void {
    for (world.tint_cues.entities(), world.tint_cues.slice()) |idx, cue| {
        const cursor = world.tint_cursors.get(idx) orelse continue;
        if (dt_s > 0) cursor.time_s += dt_s;

        const raw: f64 = blk: {
            const col = world.dataColumn(cue.selector) orelse break :blk 0;
            break :blk world.data.get(col, idx) orelse 0;
        };
        cursor.color = resolve(cue, raw, cursor.time_s);
    }
}

/// The resolved override color for `cue` at selector value `raw` and blink-phase clock
/// `time_s`, or `null` for "no override" (`raw` is not a valid 1-based `states` index).
/// Guards `raw` against NaN/negative/out-of-range before any float→int cast, so a bad
/// selector value can never trap — it just resolves to "no override". Pure.
fn resolve(cue: TintCue, raw: f64, time_s: f32) ?[3]f32 {
    const max_f: f64 = @floatFromInt(cue.states.len);
    if (!(raw >= 1) or raw > max_f) return null; // 0, absent, negative, NaN, or OOB
    const i: usize = @intFromFloat(@round(raw));
    if (i == 0 or i > cue.states.len) return null;
    const state = cue.states[i - 1];
    const alt = state.blink_color orelse return state.color;
    const phase = time_s * state.blink_hz;
    const frac = phase - @floor(phase);
    return if (frac < 0.5) state.color else alt;
}

const testing = std.testing;

test "tint: no TintCue on the entity ⇒ no cursor, advance is a no-op" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    advance(&w, 0.1);
    try testing.expect(w.getTintCursor(e) == null);
}

test "tint: selector 0 (default) resolves to no override" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTintCue(e, .{ .selector = "mode", .states = &.{.{ .color = .{ 0.2, 0.3, 1.0 } }} });
    try w.setDataByName(e, "mode", 0);

    advance(&w, 0.1);
    try testing.expectEqual(@as(?[3]f32, null), w.getTintCursor(e).?.color);
}

test "tint: an undeclared selector resolves to no override, never a crash" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    // "mode" is never registered as a data component on this entity or any other.
    try w.setTintCue(e, .{ .selector = "mode", .states = &.{.{ .color = .{ 1, 0, 0 } }} });

    advance(&w, 0.1);
    try testing.expectEqual(@as(?[3]f32, null), w.getTintCursor(e).?.color);
}

test "tint: selector 1 resolves to states[0]'s solid color" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTintCue(e, .{ .selector = "frightened", .states = &.{
        .{ .color = .{ 0.2, 0.3, 1.0 } },
    } });
    try w.setDataByName(e, "frightened", 1);

    advance(&w, 0.1);
    try testing.expectEqual(@as(?[3]f32, .{ 0.2, 0.3, 1.0 }), w.getTintCursor(e).?.color);
}

test "tint: an out-of-range selector value resolves to no override" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTintCue(e, .{ .selector = "mode", .states = &.{.{ .color = .{ 1, 0, 0 } }} }); // one state
    try w.setDataByName(e, "mode", 7); // no states[6]

    advance(&w, 0.1);
    try testing.expectEqual(@as(?[3]f32, null), w.getTintCursor(e).?.color);
}

test "tint: a blinking state alternates color/blink_color as a wall-clock square wave" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    // 2 Hz blink: 0.25s period-halves. On for [0, 0.25), off for [0.25, 0.5), etc.
    try w.setTintCue(e, .{ .selector = "frightened", .states = &.{
        .{ .color = .{ 0.2, 0.3, 1.0 }, .blink_color = .{ 0.9, 0.9, 0.95 }, .blink_hz = 2 },
    } });
    try w.setDataByName(e, "frightened", 1);

    advance(&w, 0.1); // time_s = 0.1 < 0.25 ⇒ "on" (base color)
    try testing.expectEqual(@as(?[3]f32, .{ 0.2, 0.3, 1.0 }), w.getTintCursor(e).?.color);

    advance(&w, 0.2); // time_s = 0.3 ⇒ within [0.25, 0.5) ⇒ "off" (blink color)
    try testing.expectEqual(@as(?[3]f32, .{ 0.9, 0.9, 0.95 }), w.getTintCursor(e).?.color);

    advance(&w, 0.2); // time_s = 0.5 ⇒ wraps back to "on"
    try testing.expectEqual(@as(?[3]f32, .{ 0.2, 0.3, 1.0 }), w.getTintCursor(e).?.color);
}

test "tint: dt_s <= 0 does not advance the blink phase" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTintCue(e, .{ .selector = "m", .states = &.{
        .{ .color = .{ 1, 1, 1 }, .blink_color = .{ 0, 0, 0 }, .blink_hz = 1 },
    } });
    try w.setDataByName(e, "m", 1);

    advance(&w, 0.4);
    const first = w.getTintCursor(e).?.color;
    advance(&w, 0); // no-op
    advance(&w, -1); // no-op
    try testing.expectEqual(first, w.getTintCursor(e).?.color);
    try testing.expectEqual(@as(f32, 0.4), w.getTintCursor(e).?.time_s);
}

test "tint: advancing the cursor never perturbs the state hash (cosmetic, wall-clock)" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } }); // hashed state
    try w.setTintCue(e, .{ .selector = "frightened", .states = &.{
        .{ .color = .{ 0.2, 0.3, 1.0 }, .blink_color = .{ 1, 1, 1 }, .blink_hz = 4 },
    } });
    try w.setDataByName(e, "frightened", 1); // a data component write DOES enter the hash

    const before = w.stateHash();
    advance(&w, 1.0);
    // The cursor actually moved (the test is meaningful)…
    try testing.expect(w.getTintCursor(e).?.time_s != 0);
    // …yet the hash is byte-identical: the blink phase is wall-clock-driven and
    // hash-excluded (only the selector WRITE above — already reflected in `before` —
    // is sim state).
    try testing.expectEqual(before, w.stateHash());
}

test "tint: setTintCue attaches a default cursor once and preserves an in-progress one on re-declare" {
    const gpa = testing.allocator;
    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTintCue(e, .{ .selector = "m", .states = &.{} });
    try testing.expectEqual(@as(f32, 0), w.getTintCursor(e).?.time_s);

    w.getTintCursor(e).?.time_s = 5;
    try w.setTintCue(e, .{ .selector = "m", .states = &.{} }); // re-declare
    try testing.expectEqual(@as(f32, 5), w.getTintCursor(e).?.time_s); // not reset
}
