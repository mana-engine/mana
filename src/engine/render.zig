//! Render preparation: turn a `World` into backend-ready draw data. This is the pure
//! (GPU-free, deterministic) half of rendering — it iso-projects entity transforms to
//! NDC-space quads. The gpu backend rasterizes the result. Kept pure so it is
//! testable in CI without a GPU (ADR 0006 §6: rendering correctness of the projection
//! is guarded here; pixel output is verified out-of-band).

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// How the world is framed into an image.
pub const View = struct {
    width: u32,
    height: u32,
    tile: core.math.TileMetrics,
    /// Quad half-size in pixels.
    quad_half_px: f32 = 16,
};

/// Distinct colours cycled per entity so drawn quads are visually separable.
pub const default_palette = [_][3]f32{
    .{ 0.90, 0.35, 0.40 },
    .{ 0.35, 0.80, 0.50 },
    .{ 0.40, 0.55, 0.95 },
    .{ 0.95, 0.80, 0.35 },
    .{ 0.70, 0.45, 0.90 },
};

/// Iso-project every entity transform in `world` into an NDC-space quad. The image
/// origin is the screen centre. Caller owns the returned slice. Pure/deterministic.
pub fn project(gpa: Allocator, world: *World, view: View, palette: []const [3]f32) Allocator.Error![]gpu.Quad {
    const half_w = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h = @as(f32, @floatFromInt(view.height)) / 2;
    const origin: core.Vec2 = .{ .x = half_w, .y = half_h };

    var quads: std.ArrayList(gpu.Quad) = .empty;
    errdefer quads.deinit(gpa);
    for (world.transforms.entities(), world.transforms.slice()) |entity_index, t| {
        const s = core.math.worldToScreen(t.pos, view.tile, origin);
        try quads.append(gpa, .{
            .center = .{ s.x / half_w - 1, s.y / half_h - 1 },
            .half = .{ view.quad_half_px / half_w, view.quad_half_px / half_h },
            .color = palette[entity_index % palette.len],
        });
    }
    return quads.toOwnedSlice(gpa);
}

const testing = std.testing;

test "project: an entity at the origin maps to the NDC centre" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });

    const view: View = .{ .width = 256, .height = 256, .tile = .{ .half_w = 32, .half_h = 16, .z_height = 16 } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[1], 1e-6);
}

test "project: +X and +Y move a quad the iso way (deterministic layout)" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const a = try world.spawn(); // origin
    try world.setTransform(a, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    const b = try world.spawn(); // +X: screen right and down
    try world.setTransform(b, .{ .pos = .{ .x = 1, .y = 0, .z = 0 } });

    const view: View = .{ .width = 256, .height = 256, .tile = .{ .half_w = 32, .half_h = 16, .z_height = 16 } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    // +X of one tile = +32px x, +16px y from centre → +0.25, +0.125 in NDC.
    try testing.expectApproxEqAbs(@as(f32, 0.25), quads[1].center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.125), quads[1].center[1], 1e-6);
    // Distinct entities get distinct palette colours.
    try testing.expect(!std.mem.eql(f32, &quads[0].color, &quads[1].color));
}
