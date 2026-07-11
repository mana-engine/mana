//! platform — the OS-facing port: window/input via SDL3, the main loop, and the
//! fixed-timestep driver. Concrete adapters are selected at comptime. The SDL3
//! adapter is a deferred stub; the headless adapter is the real default so the
//! sim runs from files with no window. Imports `core` only.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");

/// Available platform adapters, selected at comptime via build options.
pub const Adapter = enum { headless, sdl3 };

/// The adapter compiled into this build, chosen at comptime from `-Denable-sdl3`.
/// Defaults to headless until the SDL3 adapter lands (dependency deferral).
/// Selecting the deferred adapter fails the build with a clear reason.
pub const adapter: Adapter = if (build_options.enable_sdl3)
    @compileError("SDL3 platform adapter is not yet implemented; build without -Denable-sdl3")
else
    .headless;

/// Placeholder marker verifying the module is wired into the build graph.
pub const ready = core.ready;

test "platform module compiles headless by default" {
    try std.testing.expectEqual(Adapter.headless, adapter);
}
