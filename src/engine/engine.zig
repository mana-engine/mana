//! engine — assembles the ports and the data-oriented ECS core into a runnable
//! simulation. Headless operation is the default entry; a window is an optional
//! platform adapter, never a requirement. The fixed-timestep sim is pure and
//! deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const ecs = @import("ecs");
const gpu = @import("gpu");
const platform = @import("platform");

pub const components = @import("components.zig");
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");
pub const scene = @import("scene.zig");

pub const World = world.World;
pub const Scene = scene.Scene;
pub const Entity = ecs.Entity;
pub const Transform = components.Transform;
pub const Velocity = components.Velocity;

/// Marker verifying the module is wired into the build graph and can see every port
/// it assembles.
pub const ready =
    core.ready and data.ready and ecs.ready and gpu.ready and platform.ready;

test {
    std.testing.refAllDecls(@This());
    _ = components;
    _ = world;
    _ = systems;
    _ = scene;
}

test "engine module assembles all ports" {
    try std.testing.expect(ready);
}
