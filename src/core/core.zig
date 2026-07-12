//! core — foundational, dependency-free layer: math (vec/mat/iso transforms),
//! RNG, and time. Imports nothing above it in the module DAG. Everything here is
//! pure and deterministic (no I/O, no globals), which is what lets the simulation
//! be tested without a window or GPU.

const std = @import("std");

pub const math = @import("math.zig");
pub const rng = @import("rng.zig");
pub const time = @import("time.zig");
/// The Tracy profiler shim (ADR 0023): comptime-gated zone/frame/plot/alloc
/// wrappers that no-op unless `-Denable-tracy`. Contained here so nothing above
/// imports a Tracy type (Tracy is to `core` what Vulkan is to `gpu`).
pub const tracy = @import("tracy.zig");

// Common re-exports for ergonomic access from dependents.
pub const Vec2 = math.Vec2;
pub const Vec3 = math.Vec3;
pub const Rng = rng.Rng;

/// Marker that the module is wired into the build graph; used by ports to assert
/// the DAG is assembled.
pub const ready = true;

test {
    // Pull in every sibling file's tests (same compilation unit).
    std.testing.refAllDecls(@This());
    _ = math;
    _ = rng;
    _ = time;
    _ = tracy;
}
