//! Collision-layer filtering (ADR 0008). A collider declares which layers it *is on*
//! (`layer`) and which layers it *collides with* (`mask`). Two colliders interact
//! only when each one's mask includes the other's layer — a bidirectional handshake,
//! so a one-sided mask cannot force an interaction the other side rejects. Plain
//! bitmask data; genre-neutral (the meaning of a bit is a game's convention).

const std = @import("std");

/// Layer membership + interaction mask for one collider. Defaults to "on layer 0,
/// collides with everything", the permissive baseline.
pub const Layers = struct {
    /// Bitmask of the layers this collider belongs to.
    layer: u32 = 1,
    /// Bitmask of the layers this collider is willing to collide with.
    mask: u32 = ~@as(u32, 0),

    /// A collider on every layer that collides with every layer (never filtered).
    pub const all: Layers = .{ .layer = ~@as(u32, 0), .mask = ~@as(u32, 0) };

    /// True if `a` and `b` are allowed to collide (bidirectional agreement).
    pub fn canCollide(a: Layers, b: Layers) bool {
        return (a.mask & b.layer) != 0 and (b.mask & a.layer) != 0;
    }
};

const testing = std.testing;

test "layers: default permissive layers always collide" {
    try testing.expect(Layers.canCollide(.{}, .{}));
    try testing.expect(Layers.canCollide(Layers.all, .{}));
}

test "layers: disjoint masks do not collide" {
    const player: Layers = .{ .layer = 0b001, .mask = 0b010 }; // hits enemies only
    const enemy: Layers = .{ .layer = 0b010, .mask = 0b001 }; // hits players only
    const wall: Layers = .{ .layer = 0b100, .mask = 0b000 }; // collides with nothing
    try testing.expect(Layers.canCollide(player, enemy));
    try testing.expect(!Layers.canCollide(player, wall));
    try testing.expect(!Layers.canCollide(enemy, wall));
}

test "layers: filtering is bidirectional" {
    const a: Layers = .{ .layer = 0b01, .mask = 0b10 }; // wants to hit b's layer
    const b: Layers = .{ .layer = 0b10, .mask = 0b00 }; // refuses everything
    try testing.expect(!Layers.canCollide(a, b));
    try testing.expect(!Layers.canCollide(b, a));
}
