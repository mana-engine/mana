//! Narrow-phase overlap predicates for the 2.5D adapter (ADR 0008). Each returns
//! `true` when two positioned bodies share any point (touching counts as overlap).
//! The math is squared-distance vs squared-radius on the XY plane — no square roots,
//! no allocation, fully deterministic. This is the concrete "circle/capsule vs
//! static geometry" test the collision system runs on broad-phase candidates.

const std = @import("std");
const core = @import("core");
const shape = @import("shape.zig");

const Vec2 = core.Vec2;
const Body = shape.Body;
const Circle = shape.Circle;
const Capsule = shape.Capsule;

/// True if two positioned bodies overlap. Dispatches on the body kinds.
pub fn overlap(a: Body, b: Body) bool {
    return switch (a) {
        .circle => |ca| switch (b) {
            .circle => |cb| circleCircle(ca, cb),
            .capsule => |cb| circleCapsule(ca, cb),
        },
        .capsule => |ca| switch (b) {
            .circle => |cb| circleCapsule(cb, ca),
            .capsule => |cb| capsuleCapsule(ca, cb),
        },
    };
}

/// Two circles overlap when centre distance ≤ the sum of radii.
pub fn circleCircle(a: Circle, b: Circle) bool {
    const r = a.radius + b.radius;
    return distSq(a.center, b.center) <= r * r;
}

/// A circle and a capsule overlap when the circle centre is within (sum of radii)
/// of the capsule's spine segment.
pub fn circleCapsule(c: Circle, cap: Capsule) bool {
    const r = c.radius + cap.radius;
    return pointSegDistSq(c.center, cap.a, cap.b) <= r * r;
}

/// Two capsules overlap when their spine segments are within the sum of radii.
pub fn capsuleCapsule(a: Capsule, b: Capsule) bool {
    const r = a.radius + b.radius;
    return segSegDistSq(a.a, a.b, b.a, b.b) <= r * r;
}

/// Squared Euclidean distance between two points.
fn distSq(a: Vec2, b: Vec2) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

/// Squared distance from point `p` to segment `a`–`b`. A degenerate (zero-length)
/// segment reduces to point-to-point.
fn pointSegDistSq(p: Vec2, a: Vec2, b: Vec2) f32 {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const apx = p.x - a.x;
    const apy = p.y - a.y;
    const denom = abx * abx + aby * aby;
    if (denom == 0) return apx * apx + apy * apy;
    const t = std.math.clamp((apx * abx + apy * aby) / denom, 0, 1);
    const dx = apx - abx * t;
    const dy = apy - aby * t;
    return dx * dx + dy * dy;
}

/// Squared distance between segments `p1`–`q1` and `p2`–`q2` (Ericson, Real-Time
/// Collision Detection §5.1.9). Handles degenerate segments and parallel lines.
fn segSegDistSq(p1: Vec2, q1: Vec2, p2: Vec2, q2: Vec2) f32 {
    const d1x = q1.x - p1.x; // direction of segment 1
    const d1y = q1.y - p1.y;
    const d2x = q2.x - p2.x; // direction of segment 2
    const d2y = q2.y - p2.y;
    const rx = p1.x - p2.x;
    const ry = p1.y - p2.y;
    const a = d1x * d1x + d1y * d1y; // squared length of segment 1
    const e = d2x * d2x + d2y * d2y; // squared length of segment 2
    const f = d2x * rx + d2y * ry;
    const eps: f32 = 1e-12;

    var s: f32 = 0;
    var t: f32 = 0;
    if (a <= eps and e <= eps) {
        return rx * rx + ry * ry; // both segments are points
    }
    if (a <= eps) {
        t = std.math.clamp(f / e, 0, 1); // segment 1 is a point
    } else {
        const c = d1x * rx + d1y * ry;
        if (e <= eps) {
            s = std.math.clamp(-c / a, 0, 1); // segment 2 is a point
        } else {
            const b = d1x * d2x + d1y * d2y;
            const denom = a * e - b * b;
            if (denom != 0) s = std.math.clamp((b * f - c * e) / denom, 0, 1);
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = std.math.clamp(-c / a, 0, 1);
            } else if (t > 1) {
                t = 1;
                s = std.math.clamp((b - c) / a, 0, 1);
            }
        }
    }
    const c1x = p1.x + d1x * s;
    const c1y = p1.y + d1y * s;
    const c2x = p2.x + d2x * t;
    const c2y = p2.y + d2y * t;
    const dx = c1x - c2x;
    const dy = c1y - c2y;
    return dx * dx + dy * dy;
}

const testing = std.testing;

test "overlap: circle-vs-circle table" {
    const Case = struct { a: Circle, b: Circle, want: bool };
    const cases = [_]Case{
        // clearly overlapping (concentric)
        .{ .a = .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 }, .b = .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 }, .want = true },
        // just touching (distance == sum of radii)
        .{ .a = .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 }, .b = .{ .center = .{ .x = 2, .y = 0 }, .radius = 1 }, .want = true },
        // just separated
        .{ .a = .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 }, .b = .{ .center = .{ .x = 2.1, .y = 0 }, .radius = 1 }, .want = false },
        // diagonal overlap
        .{ .a = .{ .center = .{ .x = 0, .y = 0 }, .radius = 2 }, .b = .{ .center = .{ .x = 1, .y = 1 }, .radius = 1 }, .want = true },
        // far apart
        .{ .a = .{ .center = .{ .x = -5, .y = -5 }, .radius = 1 }, .b = .{ .center = .{ .x = 5, .y = 5 }, .radius = 1 }, .want = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, circleCircle(c.a, c.b));
        // symmetry
        try testing.expectEqual(c.want, circleCircle(c.b, c.a));
        try testing.expectEqual(c.want, overlap(.{ .circle = c.a }, .{ .circle = c.b }));
    }
}

test "overlap: circle-vs-capsule table" {
    const cap: Capsule = .{ .a = .{ .x = -2, .y = 0 }, .b = .{ .x = 2, .y = 0 }, .radius = 1 };
    const Case = struct { c: Circle, want: bool };
    const cases = [_]Case{
        // beside the spine, within combined radius
        .{ .c = .{ .center = .{ .x = 0, .y = 1.5 }, .radius = 1 }, .want = true },
        // beside the spine, just out of reach
        .{ .c = .{ .center = .{ .x = 0, .y = 2.1 }, .radius = 1 }, .want = false },
        // past the rounded end cap, still within reach
        .{ .c = .{ .center = .{ .x = 3.5, .y = 0 }, .radius = 1 }, .want = true },
        // well past the end cap
        .{ .c = .{ .center = .{ .x = 4.1, .y = 0 }, .radius = 1 }, .want = false },
    };
    for (cases) |k| {
        try testing.expectEqual(k.want, circleCapsule(k.c, cap));
        try testing.expectEqual(k.want, overlap(.{ .circle = k.c }, .{ .capsule = cap }));
        try testing.expectEqual(k.want, overlap(.{ .capsule = cap }, .{ .circle = k.c }));
    }
}

test "overlap: capsule-vs-capsule table" {
    const Case = struct { a: Capsule, b: Capsule, want: bool };
    const cases = [_]Case{
        // parallel, close
        .{
            .a = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 4, .y = 0 }, .radius = 0.5 },
            .b = .{ .a = .{ .x = 0, .y = 0.9 }, .b = .{ .x = 4, .y = 0.9 }, .radius = 0.5 },
            .want = true,
        },
        // parallel, just apart
        .{
            .a = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 4, .y = 0 }, .radius = 0.5 },
            .b = .{ .a = .{ .x = 0, .y = 1.1 }, .b = .{ .x = 4, .y = 1.1 }, .radius = 0.5 },
            .want = false,
        },
        // crossing (segments intersect)
        .{
            .a = .{ .a = .{ .x = -2, .y = 0 }, .b = .{ .x = 2, .y = 0 }, .radius = 0.1 },
            .b = .{ .a = .{ .x = 0, .y = -2 }, .b = .{ .x = 0, .y = 2 }, .radius = 0.1 },
            .want = true,
        },
        // perpendicular, endpoints apart
        .{
            .a = .{ .a = .{ .x = -2, .y = 0 }, .b = .{ .x = -1, .y = 0 }, .radius = 0.1 },
            .b = .{ .a = .{ .x = 0, .y = -2 }, .b = .{ .x = 0, .y = 2 }, .radius = 0.1 },
            .want = false,
        },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, capsuleCapsule(c.a, c.b));
        try testing.expectEqual(c.want, capsuleCapsule(c.b, c.a));
        try testing.expectEqual(c.want, overlap(.{ .capsule = c.a }, .{ .capsule = c.b }));
    }
}
