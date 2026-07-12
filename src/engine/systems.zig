//! Systems: free functions that iterate the `World` in cache order (ADR 0004 §5).
//! No behavior objects, no virtual dispatch. Systems are pure over the world state,
//! which keeps the fixed-timestep sim deterministic and testable.

const std = @import("std");
const World = @import("world.zig").World;

/// Integrate `Transform.pos += Velocity.v * dt` for every entity that has both.
/// Walks the velocity set (typically the smaller) and probes transforms.
pub fn movement(world: *World, dt: f32) void {
    for (world.velocities.entities(), world.velocities.slice()) |ei, vel| {
        if (world.transforms.get(ei)) |t| {
            t.pos = t.pos.add(vel.v.scale(dt));
        }
    }
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
