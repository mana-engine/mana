//! gpu — the renderer port. Defines the engine-owned GPU vocabulary and selects a
//! backend at comptime via build options. This is the ONLY module permitted to
//! import Vulkan types; nothing above `gpu` may see them. The Vulkan backend is
//! compiled only under `-Denable-vulkan`; the null backend is the real, testable
//! default used in headless runs and CI.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");

/// Plain-data quad the engine hands the backend to draw (no Vulkan types).
pub const Quad = @import("types.zig").Quad;

/// Available GPU backends, selected at comptime via build options.
pub const Backend = enum { null_backend, vulkan };

/// The backend compiled into this build, chosen at comptime from `-Denable-vulkan`.
pub const backend: Backend = if (build_options.enable_vulkan) .vulkan else .null_backend;

/// The Vulkan backend implementation — present only when `-Denable-vulkan` is set.
/// Kept behind the comptime flag so the `vulkan` import (and its bindings) never
/// enter a default build. Nothing above `gpu` should reference Vulkan types it
/// exposes; the engine-facing surface returns plain data (e.g. RGBA pixels).
pub const vk = if (build_options.enable_vulkan) @import("vulkan/backend.zig") else struct {};

/// Marker that the module is wired into the build graph.
pub const ready = core.ready;

test "gpu backend matches the build flag" {
    const expected: Backend = if (build_options.enable_vulkan) .vulkan else .null_backend;
    try std.testing.expectEqual(expected, backend);
}
