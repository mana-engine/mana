//! Collider geometry for the hand-rolled 2.5D adapter (ADR 0008). Collision is
//! computed on the world XY plane; Z is carried by the entity transform but does not
//! enter these tests (2.5D). A `Shape` is the *local* collider a component stores; a
//! `Body` is that shape positioned in the world, ready for an overlap test. All
//! types are plain data and every function is a pure transform (deterministic).

const std = @import("std");
const core = @import("core");

const Vec2 = core.Vec2;

/// World-space circle: every point within `radius` of `center`.
pub const Circle = struct { center: Vec2, radius: f32 };

/// World-space capsule (a 2D stadium): every point within `radius` of the segment
/// `a`–`b`. A zero-length segment degenerates to a circle.
pub const Capsule = struct { a: Vec2, b: Vec2, radius: f32 };

/// A collider positioned in the world, tagged so overlap can dispatch on its kind.
pub const Body = union(enum) {
    circle: Circle,
    capsule: Capsule,
};

/// The *local* collider shape a `Collider` component stores. `place` positions it at
/// a world center to produce a `Body`; capsule endpoints are offsets from that
/// center. Genre-neutral: just geometry, no gameplay meaning.
pub const Shape = union(enum) {
    circle: struct { radius: f32 },
    capsule: struct { a: Vec2, b: Vec2, radius: f32 },
};

/// Position local `shape` at world `center`, yielding a `Body` ready for overlap.
pub fn place(shape: Shape, center: Vec2) Body {
    return switch (shape) {
        .circle => |c| .{ .circle = .{ .center = center, .radius = c.radius } },
        .capsule => |c| .{ .capsule = .{
            .a = center.add(c.a),
            .b = center.add(c.b),
            .radius = c.radius,
        } },
    };
}

/// Axis-aligned bounding box on the XY plane. Used by the broad-phase to bucket a
/// body into grid cells; two bodies overlap only if their AABBs overlap.
pub const Aabb = struct {
    min: Vec2,
    max: Vec2,

    /// The tight AABB enclosing `body`.
    pub fn ofBody(body: Body) Aabb {
        return switch (body) {
            .circle => |c| .{
                .min = .{ .x = c.center.x - c.radius, .y = c.center.y - c.radius },
                .max = .{ .x = c.center.x + c.radius, .y = c.center.y + c.radius },
            },
            .capsule => |c| .{
                .min = .{ .x = @min(c.a.x, c.b.x) - c.radius, .y = @min(c.a.y, c.b.y) - c.radius },
                .max = .{ .x = @max(c.a.x, c.b.x) + c.radius, .y = @max(c.a.y, c.b.y) + c.radius },
            },
        };
    }
};

const testing = std.testing;

test "shape: place positions a circle at the world center" {
    const b = place(.{ .circle = .{ .radius = 2 } }, .{ .x = 3, .y = 4 });
    try testing.expect(b.circle.center.approxEql(.{ .x = 3, .y = 4 }, 1e-6));
    try testing.expectEqual(@as(f32, 2), b.circle.radius);
}

test "shape: place offsets capsule endpoints from the center" {
    const b = place(.{ .capsule = .{ .a = .{ .x = 0, .y = -1 }, .b = .{ .x = 0, .y = 1 }, .radius = 0.5 } }, .{ .x = 10, .y = 10 });
    try testing.expect(b.capsule.a.approxEql(.{ .x = 10, .y = 9 }, 1e-6));
    try testing.expect(b.capsule.b.approxEql(.{ .x = 10, .y = 11 }, 1e-6));
}

test "shape: circle AABB is the bounding square" {
    const box = Aabb.ofBody(.{ .circle = .{ .center = .{ .x = 1, .y = 2 }, .radius = 3 } });
    try testing.expect(box.min.approxEql(.{ .x = -2, .y = -1 }, 1e-6));
    try testing.expect(box.max.approxEql(.{ .x = 4, .y = 5 }, 1e-6));
}

test "shape: capsule AABB spans both endpoints plus radius" {
    const box = Aabb.ofBody(.{ .capsule = .{ .a = .{ .x = -1, .y = 0 }, .b = .{ .x = 3, .y = 0 }, .radius = 1 } });
    try testing.expect(box.min.approxEql(.{ .x = -2, .y = -1 }, 1e-6));
    try testing.expect(box.max.approxEql(.{ .x = 4, .y = 1 }, 1e-6));
}
