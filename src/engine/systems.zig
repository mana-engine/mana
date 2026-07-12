//! Systems: free functions that iterate the `World` in cache order (ADR 0004 §5).
//! No behavior objects, no virtual dispatch. Systems are pure over the world state,
//! which keeps the fixed-timestep sim deterministic and testable.

const std = @import("std");
const World = @import("world.zig").World;
const sim = @import("sim.zig");
const Context = sim.Context;
const SystemError = sim.SystemError;

/// Integrate `Transform.pos += Velocity.v * dt` for every entity that has both.
/// Walks the velocity set (typically the smaller) and probes transforms.
pub fn movement(world: *World, dt: f32) void {
    for (world.velocities.entities(), world.velocities.slice()) |ei, vel| {
        if (world.transforms.get(ei)) |t| {
            t.pos = t.pos.add(vel.v.scale(dt));
        }
    }
}

/// `movement` as a registerable frame system (ADR 0007). Never allocates, never fails.
pub fn movementSystem(ctx: *Context) SystemError!void {
    movement(ctx.world, ctx.dt);
}

/// Health regenerated per second by `regenSystem`. A single engine-wide rate suffices
/// for the sandbox; a per-entity regen rate is a content-defined-component follow-on
/// (ADR 0004 §3).
pub const regen_rate: f32 = 1.0;

/// Move each entity's `Health.current` toward `max` by `rate·dt`, clamped at `max`.
/// Iterates the health set directly; no other component is required.
pub fn regen(world: *World, rate: f32, dt: f32) void {
    for (world.healths.slice()) |*h| {
        if (h.current < h.max) h.current = @min(h.max, h.current + rate * dt);
    }
}

/// `regen` as a registerable frame system (ADR 0007). Never allocates, never fails.
pub fn regenSystem(ctx: *Context) SystemError!void {
    regen(ctx.world, regen_rate, ctx.dt);
}

const testing = std.testing;

test "movement: integrates position for entities with velocity" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const mover = try w.spawn();
    try w.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try w.setVelocity(mover, .{ .v = .{ .x = 2, .y = 0, .z = 0 } });

    const still = try w.spawn(); // transform but no velocity — must not move
    try w.setTransform(still, .{ .pos = .{ .x = 5, .y = 5, .z = 5 } });

    movement(&w, 0.5);
    movement(&w, 0.5);

    try testing.expect(w.getTransform(mover).?.pos.approxEql(.{ .x = 2, .y = 0, .z = 0 }, 1e-6));
    try testing.expect(w.getTransform(still).?.pos.approxEql(.{ .x = 5, .y = 5, .z = 5 }, 1e-6));
}

test "regen: moves current toward max and clamps, never overshooting" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const hurt = try w.spawn();
    try w.setHealth(hurt, .{ .current = 8, .max = 10 });

    const full = try w.spawn(); // already at max — must stay put
    try w.setHealth(full, .{ .current = 10, .max = 10 });

    regen(&w, 1.0, 1.0); // +1 → 9
    try testing.expectEqual(@as(f32, 9), w.getHealth(hurt).?.current);
    try testing.expectEqual(@as(f32, 10), w.getHealth(full).?.current);

    regen(&w, 1.0, 1.0); // +1 → 10 (reaches max)
    regen(&w, 1.0, 1.0); // clamps at max, no overshoot
    try testing.expectEqual(@as(f32, 10), w.getHealth(hurt).?.current);
    try testing.expectEqual(@as(f32, 10), w.getHealth(full).?.current);
}
