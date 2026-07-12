//! physics — the physics port's first adapter: a hand-rolled, deterministic 2.5D
//! collision kernel (ADR 0008). It owns the engine's collision vocabulary — circle
//! and capsule colliders, collision-layer filtering, a spatial-hash broad phase, and
//! narrow-phase overlap tests — as pure, allocation-light data and functions. It is
//! sim-side and trivially deterministic (no I/O, no globals, no floats hashed), which
//! keeps it inside the physics/VFX determinism invariant. Imports `core` only; the
//! concrete `Collider` component, the `collision` system, and `collision_begin`
//! events are composed one level up in `engine`. Box2D/Jolt may later slot behind
//! this same vocabulary via a new ADR when a game needs real dynamics.

const std = @import("std");
const core = @import("core");

pub const shape = @import("shape.zig");
pub const overlaps = @import("overlap.zig");
pub const broadphase = @import("broadphase.zig");
pub const layer = @import("layer.zig");
pub const resolve = @import("resolve.zig");

// Flat re-exports — the port's public vocabulary.
pub const Circle = shape.Circle;
pub const Capsule = shape.Capsule;
pub const Body = shape.Body;
pub const Shape = shape.Shape;
pub const Aabb = shape.Aabb;
pub const place = shape.place;
pub const overlap = overlaps.overlap;
pub const Layers = layer.Layers;
pub const SpatialHash = broadphase.SpatialHash;
pub const Pair = broadphase.Pair;
pub const Contact = resolve.Contact;
pub const contact = resolve.contact;

/// Marker that the module is wired into the build graph (mirrors the other ports).
pub const ready = core.ready;

test {
    std.testing.refAllDecls(@This());
    _ = shape;
    _ = overlaps;
    _ = broadphase;
    _ = layer;
    _ = resolve;
}

test "physics module is wired into the build graph" {
    try std.testing.expect(ready);
}
