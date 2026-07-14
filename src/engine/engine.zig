//! engine — assembles the ports and the data-oriented ECS core into a runnable
//! simulation. Headless operation is the default entry; a window is an optional
//! platform adapter, never a requirement. The fixed-timestep sim is pure and
//! deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const ecs = @import("ecs");

/// The platform port (adapter selected at comptime: headless default, SDL3 under
/// `-Denable-sdl3`). Re-exported so the runtime can open a window and poll input for
/// the interactive play loop (ADR 0009 / 0012); its surface is plain-data
/// (`InputSnapshot`, `WindowConfig`) plus an opaque native handle, never an OS type,
/// so nothing above `platform` sees SDL.
pub const platform = @import("platform");

/// The GPU port (backend selected at comptime). Re-exported so the runtime can
/// drive rendering; its engine-facing surface returns plain data, never Vulkan
/// types, so this does not leak Vulkan above `gpu`.
pub const gpu = @import("gpu");

/// The physics port (first adapter: hand-rolled 2.5D, ADR 0008). Re-exported so the
/// runtime and content can reference collider shapes and layers; it is pure,
/// sim-side, and deterministic.
pub const physics = @import("physics");

/// The data-driven game-UI subsystem (ADR 0034; issue #132). Re-exported so the runtime
/// can parse a ZON widget tree and compute its layout/hit-test; it is a `core + gpu +
/// platform` port module (no `ecs`/`data`, no Vulkan type), cosmetic and hash-excluded.
pub const ui = @import("ui");

pub const components = @import("components.zig");
pub const data_components = @import("data_components.zig");
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");
pub const command = @import("command.zig");
pub const event = @import("event.zig");
pub const timer = @import("timer.zig");
pub const sim = @import("sim.zig");
pub const scene = @import("scene.zig");
pub const tilemap = @import("tilemap.zig");
pub const prototype = @import("prototype.zig");
pub const render = @import("render.zig");
pub const render_svg = @import("render_svg.zig");
pub const render_ui = @import("render_ui.zig");
pub const animation = @import("animation.zig");
pub const sprite = @import("sprite.zig");
pub const text = @import("text.zig");
pub const tint = @import("tint.zig");
pub const collision = @import("collision.zig");
pub const controller = @import("controller.zig");
pub const nav = @import("nav.zig");
pub const input = @import("input.zig");
pub const invariants = @import("invariants.zig");
pub const scenario = @import("scenario.zig");

/// The scripting API version this build provides (ADR 0003 §5), surfaced so the
/// runtime can gate a package's required `script_api` without importing `script`
/// itself (which would risk a Lua type leaking above `engine`). A plain `u32`: the
/// `mana` version under `-Denable-lua`, else 0.
pub const script_api_version: u32 = @import("script").api_version;

pub const World = world.World;
pub const Sim = sim.Sim;
pub const Context = sim.Context;
pub const Scene = scene.Scene;
pub const Tilemap = tilemap.Tilemap;
pub const Entity = ecs.Entity;
pub const Transform = components.Transform;
pub const Velocity = components.Velocity;
pub const Health = components.Health;
pub const Collider = components.Collider;
pub const Controller = components.Controller;
pub const NavAgent = components.NavAgent;
pub const Sprite = components.Sprite;
pub const AnimationState = components.AnimationState;
pub const LoopMode = components.LoopMode;
pub const Timers = timer.Timers;

/// Marker verifying the module is wired into the build graph and can see every port
/// it assembles.
pub const ready =
    core.ready and data.ready and ecs.ready and gpu.ready and platform.ready and physics.ready and ui.ready;

test {
    std.testing.refAllDecls(@This());
    _ = components;
    _ = data_components;
    _ = world;
    _ = systems;
    _ = command;
    _ = event;
    _ = timer;
    _ = sim;
    _ = scene;
    _ = tilemap;
    _ = render;
    _ = render_svg;
    _ = render_ui;
    _ = animation;
    _ = sprite;
    _ = text;
    _ = collision;
    _ = controller;
    _ = nav;
    _ = input;
    _ = invariants;
    _ = scenario;
}

test "engine module assembles all ports" {
    try std.testing.expect(ready);
}
