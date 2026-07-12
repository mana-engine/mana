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

/// A quad plus the sort key used to order it, kept only for the duration of
/// `project`'s depth sort.
const DepthEntry = struct {
    quad: gpu.Quad,
    /// Iso depth key: world `x + y + z`. Greater = nearer/front (closer to camera
    /// in this engine's iso convention — a tile "up and to the right" in world
    /// space draws in front of one "down and to the left").
    depth: f32,
    /// Original entity index; tie-breaks equal-depth entries for full determinism.
    entity_index: u32,
};

/// Ascending by depth (far to near), ties broken by entity index. Painter's-algorithm
/// order: submitting far-to-near means a nearer quad is drawn later and lands on top,
/// so equal-footprint quads occlude correctly regardless of spawn order.
fn lessThanDepth(_: void, a: DepthEntry, b: DepthEntry) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    return a.entity_index < b.entity_index;
}

/// Iso-project every entity transform in `world` into an NDC-space quad, then sort
/// the result far-to-near by iso depth (`x + y + z`, greater = nearer) so the caller
/// can submit quads in order and get correct painter's-algorithm occlusion — nearer
/// entities are drawn later and land on top. The sort is stable and tie-breaks equal
/// depth by entity index, so output order is fully deterministic. The image origin is
/// the screen centre. Caller owns the returned slice. Pure/deterministic.
pub fn project(gpa: Allocator, world: *World, view: View, palette: []const [3]f32) Allocator.Error![]gpu.Quad {
    const half_w = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h = @as(f32, @floatFromInt(view.height)) / 2;
    const origin: core.Vec2 = .{ .x = half_w, .y = half_h };

    var entries: std.ArrayList(DepthEntry) = .empty;
    defer entries.deinit(gpa);
    for (world.transforms.entities(), world.transforms.slice()) |entity_index, t| {
        const s = core.math.worldToScreen(t.pos, view.tile, origin);
        try entries.append(gpa, .{
            .quad = .{
                .center = .{ s.x / half_w - 1, s.y / half_h - 1 },
                .half = .{ view.quad_half_px / half_w, view.quad_half_px / half_h },
                .color = palette[entity_index % palette.len],
            },
            .depth = t.pos.x + t.pos.y + t.pos.z,
            .entity_index = entity_index,
        });
    }
    std.sort.block(DepthEntry, entries.items, {}, lessThanDepth);

    var quads: std.ArrayList(gpu.Quad) = .empty;
    errdefer quads.deinit(gpa);
    for (entries.items) |e| try quads.append(gpa, e.quad);
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

test "project: quads come out far-to-near ordered by iso depth (x+y+z)" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    // Spawn (and set transforms) out of depth order, so a naive pass-through would
    // not already be sorted: near entity first, then far, then mid.
    const near = try world.spawn(); // depth 10, entity index 0
    try world.setTransform(near, .{ .pos = .{ .x = 5, .y = 5, .z = 0 } });
    const far = try world.spawn(); // depth 0, entity index 1
    try world.setTransform(far, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    const mid = try world.spawn(); // depth 4, entity index 2
    try world.setTransform(mid, .{ .pos = .{ .x = 2, .y = 2, .z = 0 } });

    const view: View = .{ .width = 256, .height = 256, .tile = .{ .half_w = 32, .half_h = 16, .z_height = 16 } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    // Output must be far -> mid -> near (ascending depth), identified by each
    // entity's palette colour (palette[entity_index % len], all distinct here).
    try testing.expectEqual(@as(usize, 3), quads.len);
    try testing.expect(std.mem.eql(f32, &quads[0].color, &default_palette[far.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[1].color, &default_palette[mid.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[2].color, &default_palette[near.index % default_palette.len]));
}

test "project: equal-depth quads tie-break deterministically by entity index" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const a = try world.spawn(); // entity index 0
    const b = try world.spawn(); // entity index 1
    // Insert b's transform before a's, so dense component-storage order (b, a) is
    // the opposite of entity-index order (a, b) — proves the tie-break keys off
    // entity index, not storage/insertion order.
    try world.setTransform(b, .{ .pos = .{ .x = 0, .y = 5, .z = 0 } }); // depth 5
    try world.setTransform(a, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } }); // depth 5

    const view: View = .{ .width = 256, .height = 256, .tile = .{ .half_w = 32, .half_h = 16, .z_height = 16 } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 2), quads.len);
    try testing.expect(std.mem.eql(f32, &quads[0].color, &default_palette[a.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[1].color, &default_palette[b.index % default_palette.len]));
}
