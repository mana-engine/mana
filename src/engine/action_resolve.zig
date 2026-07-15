//! The pure per-tick action resolver (ADR 0040 §4; issue #217): maps a tick's
//! `platform.InputSnapshot` (plus the previous tick's, for button edges) against a parsed
//! binding (`action_types.zig`) to a per-action value. Split out of `action_map.zig` so each
//! sibling stays under the ~500-line soft limit (mirroring `ui.zig` → `ui/focus.zig`); every
//! symbol is re-exported through `action_map.zig`, so callers name
//! `engine.action_map.resolveAxis2d`/`.buttonHeld`/… unchanged.
//!
//! This file depends only on the public leaf types — the parser never appears in the resolver
//! path (a determinism test below reaches for `action_parse.parse` purely to build a fixture),
//! so the split adds no circular wiring.
//!
//! **Every function here is a PURE function of its snapshot argument(s) and the binding** — no
//! globals, no time, no randomness, no allocation whose ordering could affect output (ADR 0040
//! §6). The same `(snapshot, prev_snapshot, binding)` always yields bit-identical results, and
//! nothing here feeds `World.stateHash` (the resolved value is derived per-tick from the
//! hash-excluded snapshot). Multi-source ties are broken by a fixed binding order (native analog
//! source before the key composite), never by hash-map iteration order.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const types = @import("action_types.zig");

const Vec2 = core.Vec2;
const Stick = types.Stick;
const Keys2d = types.Keys2d;
const Keys1d = types.Keys1d;
const RawAction = types.RawAction;
const ActionMap = types.ActionMap;

/// A `button` action's transition between two consecutive ticks (ADR 0040 §4): `.pressed` on
/// the down edge, `.released` on the up edge, `.none` when the combined held-state is
/// unchanged. Mirrors the `on_key` `pressed` flag (ADR 0021), collapsed to one value.
pub const ButtonEdge = enum { none, pressed, released };

/// Magnitude (Euclidean length) of `v`. PURE.
fn magnitude(v: Vec2) f32 {
    return @sqrt(Vec2.dot(v, v));
}

/// Clamp `v` to unit length: pass it through unchanged when `|v| <= 1`, else normalize to
/// exactly length 1 (ADR 0040 §4 "normalize only when magnitude exceeds 1"). This is what
/// keeps a diagonal key combo (raw length √2) from being faster than a straight input, while
/// leaving an in-range stick magnitude untouched. PURE.
fn clampToUnit(v: Vec2) Vec2 {
    const m = magnitude(v);
    if (m <= 1.0) return v;
    return v.scale(1.0 / m);
}

/// Apply a RADIAL dead-zone (ADR 0040 §4): zero the vector when its *magnitude* is within
/// `dz`, else return it unchanged (a hard radial cutoff — the value just outside the radius
/// "passes through"). Radial means the test is on `|v|`, not per-component: a diagonal just
/// inside the radius is zeroed even if each component alone would clear a per-axis threshold.
/// Applied only to native analog sources (a synthesized key vector is already clean). PURE.
fn applyDeadzone(v: Vec2, dz: f32) Vec2 {
    if (magnitude(v) <= dz) return Vec2.zero;
    return v;
}

/// 1 when any key in `group` is held in `snap`, else 0 — the OR that lets several physical
/// keys drive one direction (e.g. both arrows and WASD). PURE.
fn groupBit(group: []const platform.Key, snap: platform.InputSnapshot) f32 {
    for (group) |key| if (snap.keys.contains(key)) return 1;
    return 0;
}

/// The raw `(x, y)` of a native stick in `snap` (before dead-zone / clamp). PURE.
fn stickVec(stick: Stick, snap: platform.InputSnapshot) Vec2 {
    return switch (stick) {
        .left => .{ .x = snap.pad_axes.get(.left_x), .y = snap.pad_axes.get(.left_y) },
        .right => .{ .x = snap.pad_axes.get(.right_x), .y = snap.pad_axes.get(.right_y) },
    };
}

/// Synthesize an `axis2d` vector from a held-key composite (ADR 0040 §4): each direction group
/// is OR'd, held opposites cancel, and the raw vector (components in {-1, 0, +1}) is clamped to
/// unit length so a diagonal is not √2 faster than a straight press. Sign convention matches
/// `src/engine/input.zig`: right = +x, left = −x, down = +y, up = −y. No dead-zone — a
/// synthesized vector is already clean. PURE.
fn synthAxis2d(k: Keys2d, snap: platform.InputSnapshot) Vec2 {
    const v: Vec2 = .{
        .x = groupBit(k.right, snap) - groupBit(k.left, snap),
        .y = groupBit(k.down, snap) - groupBit(k.up, snap),
    };
    return clampToUnit(v);
}

/// Synthesize an `axis1d` value from a held `pos`/`neg` key pair (ADR 0040 §4): `pos` held ⇒
/// +1, `neg` held ⇒ −1, both or neither ⇒ 0. PURE.
fn synthAxis1d(k: Keys1d, snap: platform.InputSnapshot) f32 {
    return groupBit(k.pos, snap) - groupBit(k.neg, snap);
}

/// Whether `action`'s combined button state is held in `snap` — the logical **OR** of every
/// bound source (keyboard keys and gamepad buttons), which is what makes the action
/// device-agnostic (any bound input holds it). A non-`button` action, or one whose flat
/// sources are empty, is never held. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveButtonHeld(action: RawAction, snap: platform.InputSnapshot) bool {
    for (action.keys) |k| if (snap.keys.contains(k)) return true;
    for (action.pad_buttons) |b| if (snap.pad_buttons.contains(b)) return true;
    return false;
}

/// The `button` edge for `action` between `prev` and `snap`. Edge detection is on the
/// **OR-combined** held-state (ADR 0040 §4): releasing one bound source while another stays
/// held does NOT fire `.released`, because the OR is still true. `.pressed` on the combined
/// down transition, `.released` on the up transition, else `.none`. PURE function of
/// `(action, snap, prev)`; `action` is borrowed.
pub fn resolveButtonEdge(action: RawAction, snap: platform.InputSnapshot, prev: platform.InputSnapshot) ButtonEdge {
    const cur = resolveButtonHeld(action, snap);
    const was = resolveButtonHeld(action, prev);
    if (cur == was) return .none;
    return if (cur) .pressed else .released;
}

/// Resolve an `axis2d` action to its `(x, y)` value (ADR 0040 §4). Candidate sources are
/// evaluated in a fixed binding order — the native `pad_stick` first, then the `keys_2d`
/// composite — and the source with the **greatest magnitude** this tick wins (a resting stick
/// never overrides active keys, and vice-versa). An exact magnitude tie is broken toward the
/// earlier source (the native stick), the deterministic §4 tie-break. The native stick has the
/// per-action radial `deadzone` applied *before* comparison; both candidates are clamped to
/// unit length (so a stick beyond magnitude 1 clamps to 1). A non-`axis2d` action, or one with
/// no analog source, resolves to zero. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveAxis2d(action: RawAction, snap: platform.InputSnapshot) Vec2 {
    var best: Vec2 = Vec2.zero;
    var best_mag: f32 = -1;
    // Binding order: native stick first, then synthesized keys (tie → earlier candidate wins,
    // since a later candidate only replaces on a *strictly* greater magnitude).
    if (action.pad_stick) |stick| {
        const v = clampToUnit(applyDeadzone(stickVec(stick, snap), action.deadzone));
        const m = magnitude(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    if (action.keys_2d) |k| {
        const v = synthAxis2d(k, snap);
        const m = magnitude(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    return best;
}

/// Resolve an `axis1d` action to its `f32` value (ADR 0040 §4). Same multi-source rule as
/// `resolveAxis2d`, in one dimension: the native `pad_axis` (a trigger in [0, 1] or a stick
/// axis in [-1, 1]) vs the `pos`/`neg` key pair synthesized to {-1, 0, +1}; the source with the
/// greater `|value|` wins, ties broken toward the native axis (binding order). The native axis
/// has the radial dead-zone (in 1-D, `|value| <= deadzone` ⇒ 0) applied and is clamped to
/// [-1, 1] (the 1-D "normalize when magnitude > 1"). A non-`axis1d` action, or one with no
/// analog source, resolves to 0. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveAxis1d(action: RawAction, snap: platform.InputSnapshot) f32 {
    var best: f32 = 0;
    var best_mag: f32 = -1;
    if (action.pad_axis) |axis| {
        var v = snap.pad_axes.get(axis);
        if (@abs(v) <= action.deadzone) v = 0;
        v = std.math.clamp(v, -1, 1);
        const m = @abs(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    if (action.keys_1d) |k| {
        const v = synthAxis1d(k, snap);
        const m = @abs(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    return best;
}

// --- Poll-facing entry points, keyed by action NAME (ADR 0040 §2) ------------------
//
// These look a binding up by name in the `ActionMap` and delegate to the `resolve*` core
// above — the exact shape the #218 `mana.action_down`/`action_axis`/`action_vector` polls
// will call. An unknown action name (or a poll of the wrong value-type) reads as the neutral
// value (not held / 0 / zero-vector); type-vs-poll validation is #218's job, not the pure
// resolver's. All PURE, all borrow `map`/`name`.

/// Is the named `button` action held this tick — the device-agnostic held poll (ADR 0040 §2).
/// Unknown name ⇒ false. Delegates to `resolveButtonHeld`.
pub fn buttonHeld(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) bool {
    const action = map.find(name) orelse return false;
    return resolveButtonHeld(action, snap);
}

/// The named `button` action's edge between `prev` and `snap` (ADR 0040 §4). Unknown name ⇒
/// `.none`. Delegates to `resolveButtonEdge`.
pub fn buttonEdge(map: ActionMap, snap: platform.InputSnapshot, prev: platform.InputSnapshot, name: []const u8) ButtonEdge {
    const action = map.find(name) orelse return .none;
    return resolveButtonEdge(action, snap, prev);
}

/// The named `axis1d` action's value this tick (ADR 0040 §2). Unknown name ⇒ 0. Delegates to
/// `resolveAxis1d`.
pub fn axis1d(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) f32 {
    const action = map.find(name) orelse return 0;
    return resolveAxis1d(action, snap);
}

/// The named `axis2d` action's value this tick (ADR 0040 §2). Unknown name ⇒ zero. Delegates
/// to `resolveAxis2d`.
pub fn axis2d(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) Vec2 {
    const action = map.find(name) orelse return Vec2.zero;
    return resolveAxis2d(action, snap);
}

// --- Resolver tests (ADR 0040 §4) --------------------------------------------------

const testing = std.testing;

/// 1/√2 — the per-component value of a normalized diagonal.
const inv_sqrt2: f32 = 0.7071067811865476;

/// A four-direction `axis2d` key composite (arrow keys), shared by the axis2d tests.
const arrows: Keys2d = .{ .up = &.{.up}, .down = &.{.down}, .left = &.{.left}, .right = &.{.right} };

/// A snapshot with exactly `keys` held (no gamepad) — the injected-keyboard fixture.
fn keySnap(keys: []const platform.Key) platform.InputSnapshot {
    var s: platform.InputSnapshot = .{};
    for (keys) |k| s.keys.insert(k);
    return s;
}

test "resolver axis2d: a single held direction is a unit vector (right=+x, up=-y)" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    try testing.expectEqual(Vec2{ .x = 1, .y = 0 }, resolveAxis2d(move, keySnap(&.{.right})));
    try testing.expectEqual(Vec2{ .x = -1, .y = 0 }, resolveAxis2d(move, keySnap(&.{.left})));
    try testing.expectEqual(Vec2{ .x = 0, .y = -1 }, resolveAxis2d(move, keySnap(&.{.up})));
    try testing.expectEqual(Vec2{ .x = 0, .y = 1 }, resolveAxis2d(move, keySnap(&.{.down})));
}

test "resolver axis2d: held opposites cancel to zero" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .left, .right })));
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .up, .down })));
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .up, .down, .left, .right })));
}

test "resolver axis2d: a diagonal key combo normalizes to magnitude 1 (~0.707), not √2" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    const v = resolveAxis2d(move, keySnap(&.{ .up, .right }));
    try testing.expectApproxEqAbs(@as(f32, 1), magnitude(v), 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.x, 1e-5);
    try testing.expectApproxEqAbs(-inv_sqrt2, v.y, 1e-5);
}

test "resolver axis2d: a native stick at in-range magnitude passes through un-normalized" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 0.5); // > default_deadzone (0.15)
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v.y, 1e-6);
}

test "resolver axis2d: a native stick beyond magnitude 1 clamps to 1" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 1.0);
    s.pad_axes.set(.left_y, 1.0); // raw magnitude √2
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 1), magnitude(v), 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.x, 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.y, 1e-5);
}

test "resolver axis1d: pos only = +1, neg only = -1, both = 0" {
    const thr: RawAction = .{ .type = .axis1d, .keys_1d = .{ .pos = &.{.w}, .neg = &.{.s} } };
    try testing.expectEqual(@as(f32, 1), resolveAxis1d(thr, keySnap(&.{.w})));
    try testing.expectEqual(@as(f32, -1), resolveAxis1d(thr, keySnap(&.{.s})));
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, keySnap(&.{ .w, .s })));
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, keySnap(&.{})));
}

test "resolver axis1d: a native trigger inside the dead-zone reads 0, outside passes through" {
    const thr: RawAction = .{ .type = .axis1d, .pad_axis = .right_trigger, .deadzone = 0.15 };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.right_trigger, 0.1); // < 0.15
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, s));
    s.pad_axes.set(.right_trigger, 0.6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), resolveAxis1d(thr, s), 1e-6);
}

test "resolver button: held is the OR across key and pad sources; both must clear" {
    const jump: RawAction = .{ .type = .button, .keys = &.{.space}, .pad_buttons = &.{.south} };
    try testing.expect(resolveButtonHeld(jump, keySnap(&.{.space}))); // key alone
    var pad: platform.InputSnapshot = .{ .pad_connected = true };
    pad.pad_buttons.insert(.south);
    try testing.expect(resolveButtonHeld(jump, pad)); // pad alone
    var both = pad;
    both.keys.insert(.space);
    try testing.expect(resolveButtonHeld(jump, both)); // both
    try testing.expect(!resolveButtonHeld(jump, .{})); // neither
}

test "resolver button: no up-edge when one source releases while another stays held" {
    const jump: RawAction = .{ .type = .button, .keys = &.{.space}, .pad_buttons = &.{.south} };
    // prev: key + pad both held.
    var prev: platform.InputSnapshot = .{ .pad_connected = true };
    prev.keys.insert(.space);
    prev.pad_buttons.insert(.south);
    // now: key released, pad still held → OR still true → NO edge (the key case that must not fire).
    var pad_only: platform.InputSnapshot = .{ .pad_connected = true };
    pad_only.pad_buttons.insert(.south);
    try testing.expectEqual(ButtonEdge.none, resolveButtonEdge(jump, pad_only, prev));
    // releasing the last source fires .released.
    try testing.expectEqual(ButtonEdge.released, resolveButtonEdge(jump, .{}, prev));
    // a fresh press fires .pressed.
    try testing.expectEqual(ButtonEdge.pressed, resolveButtonEdge(jump, prev, .{}));
}

test "resolver analog multi-source: the greatest-magnitude source wins" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = arrows };
    // Resting stick + active keys → keys win.
    var s1: platform.InputSnapshot = .{ .pad_connected = true };
    s1.keys.insert(.right);
    try testing.expectEqual(Vec2{ .x = 1, .y = 0 }, resolveAxis2d(move, s1));
    // Active stick + resting keys → stick wins.
    var s2: platform.InputSnapshot = .{ .pad_connected = true };
    s2.pad_axes.set(.left_x, 0.9);
    const v2 = resolveAxis2d(move, s2);
    try testing.expectApproxEqAbs(@as(f32, 0.9), v2.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v2.y, 1e-6);
}

test "resolver analog multi-source: an exact magnitude tie is broken by binding order (native first)" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = arrows };
    // Stick full +x (mag 1) and keys full +y (mag 1) — a deliberate tie. Native (stick) is the
    // earlier binding, so it wins: the result must be the stick's (1, 0), not the keys' (0, 1).
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 1.0);
    s.keys.insert(.down);
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 1), v.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), v.y, 1e-5);
}

test "resolver dead-zone is RADIAL: a diagonal inside the radius zeroes; just outside passes" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .deadzone = 0.5 };
    // Diagonal inside the radius: each component 0.35 (would clear a 0.3 *per-axis* threshold),
    // but |v| ≈ 0.495 < 0.5 → a radial dead-zone zeroes it (a per-axis one would not).
    var inside: platform.InputSnapshot = .{ .pad_connected = true };
    inside.pad_axes.set(.left_x, 0.35);
    inside.pad_axes.set(.left_y, 0.35);
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, inside));
    // Just outside: |v| ≈ 0.566 > 0.5 → passes through unchanged.
    var outside: platform.InputSnapshot = .{ .pad_connected = true };
    outside.pad_axes.set(.left_x, 0.4);
    outside.pad_axes.set(.left_y, 0.4);
    const v = resolveAxis2d(move, outside);
    try testing.expectApproxEqAbs(@as(f32, 0.4), v.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), v.y, 1e-6);
}

test "resolver dead-zone: the engine default applies when the binding omits `deadzone`" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left }; // deadzone = default_deadzone
    try testing.expectEqual(@as(f32, 0.15), move.deadzone);
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 0.1); // < 0.15 → zeroed
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, s));
    s.pad_axes.set(.left_x, 0.2); // > 0.15 → passes
    try testing.expectApproxEqAbs(@as(f32, 0.2), resolveAxis2d(move, s).x, 1e-6);
}

test "resolver: deterministic — same snapshot resolves identically via both entry points" {
    // The parser is reached only to build the fixture `ActionMap` — the resolver path itself
    // never touches it.
    const ap = @import("action_parse.zig");
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .move = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = .{ .up = .{.up}, .down = .{.down}, .left = .{.left}, .right = .{.right} } },
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_buttons = .{.south} },
        \\    },
        \\}
    ;
    const gpa = testing.allocator;
    const map = try ap.parse(gpa, src);
    defer ap.free(gpa, map);

    var snap: platform.InputSnapshot = .{ .pad_connected = true };
    snap.keys.insert(.right);
    snap.keys.insert(.space);
    snap.pad_axes.set(.left_x, 0.8);

    const move = map.find("move").?;
    const a = resolveAxis2d(move, snap);
    const b = axis2d(map, snap, "move"); // the name-keyed entry point
    const c = resolveAxis2d(move, snap); // resolve twice → bit-identical
    try testing.expectEqual(a, b);
    try testing.expectEqual(a, c);

    const jump = map.find("jump").?;
    try testing.expectEqual(resolveButtonHeld(jump, snap), buttonHeld(map, snap, "jump"));

    // Unknown action names read as the neutral value on every poll (type/name validation is #218).
    try testing.expect(!buttonHeld(map, snap, "no_such_action"));
    try testing.expectEqual(@as(f32, 0), axis1d(map, snap, "no_such_action"));
    try testing.expectEqual(Vec2.zero, axis2d(map, snap, "no_such_action"));
    try testing.expectEqual(ButtonEdge.none, buttonEdge(map, snap, snap, "no_such_action"));
}
