//! platform — the OS-facing port: window/input via SDL3, the main loop, and the
//! fixed-timestep driver. Concrete adapters are selected at comptime. The SDL3
//! adapter is a deferred stub; the headless adapter is the real default so the sim
//! runs from files with no window. Imports `core` only.
//!
//! The port vocabulary (ADR 0009) — `Key`, `InputSnapshot`, `WindowConfig` — lives in
//! `port.zig` (plain data, no OS types); each adapter implements the same `Window`
//! surface over it and is re-exported here, exactly as `gpu` re-exports its backend's
//! `Device`. A `Window` yields an opaque native surface handle (`?*anyopaque`) that
//! the `gpu` port builds a swapchain from (ADR 0012); `platform` and `gpu` never
//! import each other — `engine` bridges the handle.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");
const port = @import("port.zig");

/// Available platform adapters, selected at comptime via build options.
pub const Adapter = enum { headless, sdl3 };

/// The adapter compiled into this build, chosen at comptime from `-Denable-sdl3`.
/// Defaults to headless; `-Denable-sdl3` selects the SDL3 adapter (pulls in the
/// build-from-source SDL3 dependency).
pub const adapter: Adapter = if (build_options.enable_sdl3) .sdl3 else .headless;

/// The adapter module implementing the `Window` surface. Internal: callers use the
/// vocabulary below and the re-exported `Window`. The SDL3 branch is compiled only
/// under `-Denable-sdl3`, which links the SDL3 library (ADR 0002/0009).
const impl = if (build_options.enable_sdl3)
    @import("sdl3/adapter.zig")
else
    @import("headless/adapter.zig");

// --- Port vocabulary (engine-owned, OS-free; ADR 0009) ---------------------------
pub const Key = port.Key;
pub const KeySet = port.KeySet;
pub const MouseButtons = port.MouseButtons;
pub const InputSnapshot = port.InputSnapshot;
pub const WindowConfig = port.WindowConfig;

/// An OS window: the port's presentation + input object (ADR 0009 / 0012). The
/// selected adapter provides the concrete type — the headless adapter is a real,
/// OS-free window (the default); the SDL3 adapter (deferred) a real one. A window is
/// opened from a `WindowConfig`, `poll`ed once per tick for an `InputSnapshot`, and
/// yields an opaque native surface handle (`surfaceHandle`) that the `gpu` port turns
/// into a swapchain. Adapter-owned.
pub const Window = impl.Window;

/// Marker verifying the module is wired into the build graph.
pub const ready = core.ready;

test "platform selects the adapter matching the build flag (headless by default)" {
    const expected: Adapter = if (build_options.enable_sdl3) .sdl3 else .headless;
    try std.testing.expectEqual(expected, adapter);
}

test {
    _ = port;
    _ = impl;
}
