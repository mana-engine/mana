//! engine — assembles the ports and the data-oriented core into a runnable
//! simulation. Headless operation is the default entry point; a window is an
//! optional platform adapter, never a requirement. Imports core + data + ecs +
//! gpu + platform. Genre-agnostic: nothing game-specific lives here.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const ecs = @import("ecs");
const gpu = @import("gpu");
const platform = @import("platform");

pub const sim = @import("sim.zig");
pub const scene = @import("scene.zig");
pub const Sim = sim.Sim;
pub const Scene = scene.Scene;
pub const Entity = scene.Entity;

/// Marker verifying the module is wired into the build graph and can see every
/// port it assembles.
pub const ready =
    core.ready and data.ready and ecs.ready and gpu.ready and platform.ready;

test {
    std.testing.refAllDecls(@This());
    _ = sim;
    _ = scene;
}

test "engine module assembles all ports" {
    try std.testing.expect(ready);
}
