//! Contact resolution for the 2.5D adapter (ADR 0008 follow-on). Given two
//! overlapping bodies, `contact` returns the separating normal and penetration depth
//! needed to push `a` clear of `b`. This is the vocabulary the kinematic character
//! controller (`engine.controller`) uses to depenetrate and slide after a tentative
//! move — a discrete, overlap-based stand-in for the not-yet-implemented sweep query
//! (ADR 0008 names raycast/sweep/controller as unimplemented follow-ons; nothing in
//! the corpus yet needs continuous collision, so the controller works from overlap
//! alone rather than pulling sweep in speculatively). Pure, deterministic, no
//! allocation; the shape dispatch mirrors `overlap.zig`.

const std = @import("std");
const core = @import("core");
const shape = @import("shape.zig");
const overlap_geom = @import("overlap.zig");

const Vec2 = core.Vec2;
const Body = shape.Body;
const Circle = shape.Circle;
const Capsule = shape.Capsule;

/// Separation for one overlapping pair: translating `a` by `normal.scale(depth)`
/// (`normal` unit length, points from `b` toward `a`) moves it to just touch `b`.
pub const Contact = struct { normal: Vec2, depth: f32 };

/// Contact info for `a` vs `b`, or `null` if they do not overlap. Dispatches on body
/// kind, mirroring `overlap.overlap`.
pub fn contact(a: Body, b: Body) ?Contact {
    return switch (a) {
        .circle => |ca| switch (b) {
            .circle => |cb| circleCircle(ca, cb),
            .capsule => |cb| circleCapsule(ca, cb),
        },
        .capsule => |ca| switch (b) {
            .circle => |cb| if (circleCapsule(cb, ca)) |c|
                Contact{ .normal = c.normal.scale(-1), .depth = c.depth }
            else
                null,
            .capsule => |cb| capsuleCapsule(ca, cb),
        },
    };
}

/// Unit vector from `b` to `a` (`d = a - b`), or `fallback` if they are coincident
/// (distance ~0, direction undefined) — keeps the resolver total instead of dividing
/// by zero.
fn normalOrFallback(d: Vec2, dist: f32, fallback: Vec2) Vec2 {
    if (dist <= 1e-9) return fallback;
    return d.scale(1.0 / dist);
}

/// Contact between two circles: `null` unless centres are closer than the summed
/// radii.
pub fn circleCircle(a: Circle, b: Circle) ?Contact {
    const d = a.center.sub(b.center);
    const dist = @sqrt(d.x * d.x + d.y * d.y);
    const r = a.radius + b.radius;
    if (dist >= r) return null;
    return .{ .normal = normalOrFallback(d, dist, .{ .x = 1, .y = 0 }), .depth = r - dist };
}

/// Closest point on segment `a`-`b` to point `p`. Degenerates to `a` for a
/// zero-length segment.
fn closestOnSegment(p: Vec2, a: Vec2, b: Vec2) Vec2 {
    const ab = b.sub(a);
    const denom = ab.x * ab.x + ab.y * ab.y;
    if (denom == 0) return a;
    const t = std.math.clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / denom, 0, 1);
    return a.add(ab.scale(t));
}

/// Contact between a circle and a capsule: `null` unless the circle centre is closer
/// to the capsule's spine than the summed radii. `normal` points from the capsule
/// toward the circle.
pub fn circleCapsule(c: Circle, cap: Capsule) ?Contact {
    const cp = closestOnSegment(c.center, cap.a, cap.b);
    const d = c.center.sub(cp);
    const dist = @sqrt(d.x * d.x + d.y * d.y);
    const r = c.radius + cap.radius;
    if (dist >= r) return null;
    return .{ .normal = normalOrFallback(d, dist, .{ .x = 1, .y = 0 }), .depth = r - dist };
}

/// Contact between two capsules: `null` unless their spine segments are closer than
/// the summed radii. Reuses the closest-segment-points computation `overlap.zig`
/// runs for its overlap test.
pub fn capsuleCapsule(a: Capsule, b: Capsule) ?Contact {
    const cp = overlap_geom.closestSegSeg(a.a, a.b, b.a, b.b);
    const d = cp.c1.sub(cp.c2);
    const dist = @sqrt(d.x * d.x + d.y * d.y);
    const r = a.radius + b.radius;
    if (dist >= r) return null;
    return .{ .normal = normalOrFallback(d, dist, .{ .x = 1, .y = 0 }), .depth = r - dist };
}

const testing = std.testing;

test "resolve: overlapping circles report a normal pointing from b to a, depth = radii sum minus distance" {
    const a: Circle = .{ .center = .{ .x = 1, .y = 0 }, .radius = 1 };
    const b: Circle = .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 };
    const c = circleCircle(a, b).?;
    try testing.expect(c.normal.approxEql(.{ .x = 1, .y = 0 }, 1e-6));
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.depth, 1e-6); // radii sum 2, dist 1
}

test "resolve: separated circles have no contact" {
    try testing.expect(circleCircle(
        .{ .center = .{ .x = 0, .y = 0 }, .radius = 1 },
        .{ .center = .{ .x = 5, .y = 0 }, .radius = 1 },
    ) == null);
}

test "resolve: circle vs capsule contact pushes away from the spine" {
    const cap: Capsule = .{ .a = .{ .x = -5, .y = 0 }, .b = .{ .x = 5, .y = 0 }, .radius = 1 };
    const c: Circle = .{ .center = .{ .x = 0, .y = 1.5 }, .radius = 1 };
    const info = circleCapsule(c, cap).?;
    try testing.expect(info.normal.approxEql(.{ .x = 0, .y = 1 }, 1e-6));
    try testing.expectApproxEqAbs(@as(f32, 0.5), info.depth, 1e-6); // radii sum 2, dist 1.5
}

test "resolve: capsule vs capsule contact uses the closest spine points" {
    const a: Capsule = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 4, .y = 0 }, .radius = 0.5 };
    const b: Capsule = .{ .a = .{ .x = 0, .y = 0.5 }, .b = .{ .x = 4, .y = 0.5 }, .radius = 0.5 };
    const c = contact(.{ .capsule = a }, .{ .capsule = b }).?;
    try testing.expect(c.normal.approxEql(.{ .x = 0, .y = -1 }, 1e-6)); // a sits below b
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.depth, 1e-6); // radii sum 1, dist 0.5
}

test "resolve: contact dispatch is antisymmetric between circle and capsule order" {
    const cap: Capsule = .{ .a = .{ .x = -5, .y = 0 }, .b = .{ .x = 5, .y = 0 }, .radius = 1 };
    const c: Circle = .{ .center = .{ .x = 0, .y = 1.5 }, .radius = 1 };
    const forward = contact(.{ .circle = c }, .{ .capsule = cap }).?;
    const backward = contact(.{ .capsule = cap }, .{ .circle = c }).?;
    try testing.expectApproxEqAbs(forward.depth, backward.depth, 1e-6);
    try testing.expect(forward.normal.approxEql(backward.normal.scale(-1), 1e-6));
}
