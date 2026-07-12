//! Input-translation system (ADR 0009 §3; issue #30 — input delivery into the sim).
//! This is the seam between the platform port's per-tick `InputSnapshot`
//! (`Sim.input`, set via `Sim.setInput`, exposed to systems as `Context.input`) and
//! world state: an ordinary ADR 0007 `System`, registered like any other, with no
//! change to `Sim.tick`'s orchestration or signature. It reads the held arrow keys
//! and records a `set_velocity` command (never mutates the world directly — ADR
//! 0007 §2/§3) for every entity that already carries a `Velocity`, so the existing
//! `movementSystem` integrates the resulting displacement at the next tick.
//!
//! Deliberately genre-agnostic (CLAUDE.md invariant #6: no genre concept in `src/`):
//! this is the delivery-mechanism proof, not a game. It does not know what a
//! "player" is — a real game's content decides which entities are input-driven by
//! whichever components/scene data it attaches; here every `Velocity`-bearing
//! entity reacts alike, which is sufficient to demonstrate and test delivery.
//!
//! Deterministic: `ctx.input` is one immutable value for the whole tick (ADR 0009
//! §4), so a fixed sequence of snapshots fed one per tick via `Sim.setInput`
//! reproduces bit-identical state every run — the basis for headless input replay.

const std = @import("std");
const components = @import("components.zig");
const Context = @import("sim.zig").Context;
const SystemError = @import("sim.zig").SystemError;

/// World units per second an input-driven entity moves along a held direction.
pub const move_speed: f32 = 4.0;

/// Translate this tick's held arrow keys into a `Velocity`, queued for every entity
/// that already has one (overwriting it — a no-op for the deferred write itself, but
/// deterministic: the resulting value is the same regardless of what was set the
/// previous tick). No keys held ⇒ zero velocity, so the demo path with no
/// `setInput` call ever made is identical to before input delivery existed
/// (`ctx.input` defaults to all-empty). Errors: only `error.OutOfMemory`, propagated
/// from queuing the command; never reports `error.SystemFailed`.
pub fn inputMoveSystem(ctx: *Context) SystemError!void {
    var x: f32 = 0;
    var y: f32 = 0;
    if (ctx.input.keys.contains(.left)) x -= 1;
    if (ctx.input.keys.contains(.right)) x += 1;
    if (ctx.input.keys.contains(.up)) y -= 1; // .up/.down map to -y/+y (arrow-key mental model)
    if (ctx.input.keys.contains(.down)) y += 1;

    const v: components.Velocity = .{ .v = .{ .x = x * move_speed, .y = y * move_speed, .z = 0 } };
    for (ctx.world.velocities.entities()) |ei| {
        try ctx.commands.setVelocity(ctx.gpa, ctx.world.entityAt(ei), v);
    }
}

const testing = std.testing;
const Sim = @import("sim.zig").Sim;
const platform = @import("platform");

test "inputMoveSystem: a held arrow key drives velocity, and movement integrates it into position" {
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setVelocity(e, .{ .v = .{ .x = 0, .y = 0, .z = 0 } });

    try sim.addSystem(inputMoveSystem);
    try sim.addSystem(@import("systems.zig").movementSystem);

    var snapshot: platform.InputSnapshot = .{};
    snapshot.keys.insert(.right);
    sim.setInput(snapshot); // held for every subsequent tick (Sim.input persists)

    // A queued `set_velocity` command lands at *this* tick's flush (ADR 0007 §3), so
    // `movementSystem` (which reads the world directly, same tick) sees it starting
    // the *next* tick. `run(3)` covers that one-tick lag with room to spare.
    try sim.run(3);

    const p = sim.world.getTransform(e).?.pos;
    try testing.expect(p.x > 0); // moved right
    try testing.expectEqual(@as(f32, 0), p.y); // no vertical drift
}

test "inputMoveSystem: no keys held leaves velocity at zero, matching the pre-input-delivery default" {
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 1, .y = 1, .z = 1 } });
    try sim.world.setVelocity(e, .{ .v = .{ .x = 0, .y = 0, .z = 0 } });

    try sim.addSystem(inputMoveSystem);
    try sim.addSystem(@import("systems.zig").movementSystem);

    try sim.run(3); // never called setInput: Context.input defaults to empty every tick

    try testing.expect(sim.world.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 1, .z = 1 }, 1e-6));
    try testing.expect(sim.world.getVelocity(e).?.v.approxEql(.{ .x = 0, .y = 0, .z = 0 }, 1e-6));
}

/// A fixed per-tick trace of held keys, replayed one entry per tick via `Sim.setInput`
/// ahead of `Sim.tick` — the shape a recorded input-replay stream would follow.
const replay_trace = [_]platform.Key{ .right, .right, .down, .down, .down, .left, .up, .up };

fn runReplay(gpa: std.mem.Allocator) !u64 {
    var sim = Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();

    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setVelocity(e, .{ .v = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.addSystem(inputMoveSystem);
    try sim.addSystem(@import("systems.zig").movementSystem);

    for (replay_trace) |key| {
        var snapshot: platform.InputSnapshot = .{};
        snapshot.keys.insert(key);
        sim.setInput(snapshot);
        try sim.tick();
    }
    return sim.stateHash();
}

test "input replay: a fixed per-tick snapshot trace reproduces a bit-identical state hash" {
    const a = try runReplay(testing.allocator);
    const b = try runReplay(testing.allocator);
    try testing.expectEqual(a, b);
}
