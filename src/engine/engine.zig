//! engine — assembles the ports and the data-oriented ECS core into a runnable
//! simulation. Headless operation is the default entry; a window is an optional
//! platform adapter, never a requirement. The fixed-timestep sim is pure and
//! deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const ecs = @import("ecs");
const platform = @import("platform");

/// The GPU port (backend selected at comptime). Re-exported so the runtime can
/// drive rendering; its engine-facing surface returns plain data, never Vulkan
/// types, so this does not leak Vulkan above `gpu`.
pub const gpu = @import("gpu");

/// The physics port (first adapter: hand-rolled 2.5D, ADR 0008). Re-exported so the
/// runtime and content can reference collider shapes and layers; it is pure,
/// sim-side, and deterministic.
pub const physics = @import("physics");

pub const components = @import("components.zig");
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");
pub const command = @import("command.zig");
pub const event = @import("event.zig");
pub const timer = @import("timer.zig");
pub const sim = @import("sim.zig");
pub const scene = @import("scene.zig");
pub const render = @import("render.zig");
pub const collision = @import("collision.zig");

pub const World = world.World;
pub const Sim = sim.Sim;
pub const Context = sim.Context;
pub const Scene = scene.Scene;
pub const Entity = ecs.Entity;
pub const Transform = components.Transform;
pub const Velocity = components.Velocity;
pub const Health = components.Health;
pub const Collider = components.Collider;
pub const Timers = timer.Timers;

/// Marker verifying the module is wired into the build graph and can see every port
/// it assembles.
pub const ready =
    core.ready and data.ready and ecs.ready and gpu.ready and platform.ready and physics.ready;

test {
    std.testing.refAllDecls(@This());
    _ = components;
    _ = world;
    _ = systems;
    _ = command;
    _ = event;
    _ = timer;
    _ = sim;
    _ = scene;
    _ = render;
    _ = collision;
}

test "engine module assembles all ports" {
    try std.testing.expect(ready);
}
