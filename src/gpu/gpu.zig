//! gpu — the renderer port. Defines the engine-owned GPU vocabulary
//! (Buffer, Texture, Pipeline, CommandList) and selects a backend at comptime.
//! This is the ONLY module permitted to import Vulkan types; nothing above `gpu`
//! may see them. The Vulkan backend is a deferred stub; the null backend is the
//! real, testable default adapter used in headless runs.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");

/// Available GPU backends, selected at comptime via build options.
pub const Backend = enum { null_backend, vulkan };

/// The backend compiled into this build, chosen at comptime from `-Denable-vulkan`.
/// Defaults to the null backend until the Vulkan adapter lands (dependency
/// deferral). Selecting the deferred backend fails the build with a clear reason
/// rather than silently linking a missing implementation.
pub const backend: Backend = if (build_options.enable_vulkan)
    @compileError("Vulkan gpu backend is not yet implemented; build without -Denable-vulkan")
else
    .null_backend;

/// Placeholder marker verifying the module is wired into the build graph.
pub const ready = core.ready;

test "gpu module compiles with the null backend by default" {
    try std.testing.expectEqual(Backend.null_backend, backend);
}
