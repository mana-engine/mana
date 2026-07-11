//! Pure math for the engine core: 2D/3D vectors and isometric projection between
//! world space and screen space. No I/O, no globals — every function is a pure
//! transform, which is what makes the simulation testable without a window.

const std = @import("std");

/// A 2D vector (screen space, or world XY). Fields are plain data.
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const zero: Vec2 = .{ .x = 0, .y = 0 };

    /// Component-wise sum.
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    /// Component-wise difference (`a - b`).
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    /// Scale by a scalar.
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    /// True if both components are within `eps` of `b`'s.
    pub fn approxEql(a: Vec2, b: Vec2, eps: f32) bool {
        return std.math.approxEqAbs(f32, a.x, b.x, eps) and
            std.math.approxEqAbs(f32, a.y, b.y, eps);
    }
};

/// A 3D vector in world space (X east-ish, Y south-ish on the grid, Z up).
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    /// Component-wise sum.
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    /// Scale by a scalar.
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    /// True if all components are within `eps` of `b`'s.
    pub fn approxEql(a: Vec3, b: Vec3, eps: f32) bool {
        return std.math.approxEqAbs(f32, a.x, b.x, eps) and
            std.math.approxEqAbs(f32, a.y, b.y, eps) and
            std.math.approxEqAbs(f32, a.z, b.z, eps);
    }
};

/// Screen-space deltas for one world unit, defining the isometric projection.
/// A classic 2:1 diamond tile of pixel size WxH uses `half_w = W/2`, `half_h = H/4`.
pub const TileMetrics = struct {
    /// Horizontal screen offset per world-X (and negated per world-Y).
    half_w: f32,
    /// Vertical screen offset per world-X (and per world-Y).
    half_h: f32,
    /// Vertical screen offset per world-Z (how tall one Z unit draws), upward.
    z_height: f32,
};

/// Project a world-space point to screen space. `origin` is the screen pixel that
/// world `(0,0,0)` maps to (typically the viewport center). Pure and total.
pub fn worldToScreen(world: Vec3, tile: TileMetrics, origin: Vec2) Vec2 {
    return .{
        .x = origin.x + (world.x - world.y) * tile.half_w,
        .y = origin.y + (world.x + world.y) * tile.half_h - world.z * tile.z_height,
    };
}

/// Inverse of `worldToScreen` on the ground plane (assumes world Z = 0). Recovers
/// the world XY under a screen pixel. `half_w`/`half_h` must be non-zero.
pub fn screenToWorld(screen: Vec2, tile: TileMetrics, origin: Vec2) Vec3 {
    const rx = (screen.x - origin.x) / tile.half_w;
    const ry = (screen.y - origin.y) / tile.half_h;
    return .{
        .x = (rx + ry) * 0.5,
        .y = (ry - rx) * 0.5,
        .z = 0,
    };
}

const testing = std.testing;

test "iso projection: origin maps to screen center" {
    const tile: TileMetrics = .{ .half_w = 32, .half_h = 16, .z_height = 16 };
    const center: Vec2 = .{ .x = 640, .y = 360 };
    try testing.expect(worldToScreen(Vec3.zero, tile, center).approxEql(center, 1e-4));
}

test "iso projection: table of world->screen cases" {
    const tile: TileMetrics = .{ .half_w = 32, .half_h = 16, .z_height = 16 };
    const origin: Vec2 = .{ .x = 0, .y = 0 };
    const Case = struct { w: Vec3, s: Vec2 };
    const cases = [_]Case{
        // identity at origin
        .{ .w = .{ .x = 0, .y = 0, .z = 0 }, .s = .{ .x = 0, .y = 0 } },
        // +X moves right and down the diamond
        .{ .w = .{ .x = 1, .y = 0, .z = 0 }, .s = .{ .x = 32, .y = 16 } },
        // +Y moves left and down
        .{ .w = .{ .x = 0, .y = 1, .z = 0 }, .s = .{ .x = -32, .y = 16 } },
        // +Z lifts straight up (negative screen-y)
        .{ .w = .{ .x = 0, .y = 0, .z = 1 }, .s = .{ .x = 0, .y = -16 } },
        // negative coords
        .{ .w = .{ .x = -2, .y = -1, .z = 0 }, .s = .{ .x = -32, .y = -48 } },
    };
    for (cases) |c| {
        try testing.expect(worldToScreen(c.w, tile, origin).approxEql(c.s, 1e-4));
    }
}

test "iso projection: screen<->world round-trips on the ground plane" {
    const tile: TileMetrics = .{ .half_w = 32, .half_h = 16, .z_height = 16 };
    const origin: Vec2 = .{ .x = 640, .y = 360 };
    const worlds = [_]Vec3{
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 3, .y = 5, .z = 0 },
        .{ .x = -4, .y = 2, .z = 0 },
        .{ .x = -7, .y = -9, .z = 0 },
    };
    for (worlds) |w| {
        const back = screenToWorld(worldToScreen(w, tile, origin), tile, origin);
        try testing.expect(back.approxEql(w, 1e-3));
    }
}
