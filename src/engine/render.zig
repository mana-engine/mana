//! Render preparation: turn a `World` into backend-ready draw data. This is the pure
//! (GPU-free, deterministic) half of rendering — it projects entity transforms to
//! NDC-space quads through a configurable camera projection (ADR 0014: isometric is
//! one view, not mandatory). The gpu backend rasterizes the result. Kept pure so it is
//! testable in CI without a GPU (ADR 0006 §6: rendering correctness of the projection
//! is guarded here; pixel output is verified out-of-band).

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// How the world is framed into an image: pixel dimensions plus the projection that
/// maps world coordinates to the screen. The projection is a view-time choice (ADR
/// 0014); the sim never reads it.
pub const View = struct {
    width: u32,
    height: u32,
    /// World→screen mapping. Defaults to top-down orthographic; content asks for
    /// isometric explicitly (invariant #6: the engine has no default genre/camera).
    projection: Projection = .{ .orthographic = .{} },
    /// Quad half-size in pixels.
    quad_half_px: f32 = 16,
};

/// How world coordinates map to the screen (ADR 0014). A tagged union so new camera
/// kinds (side, 2.5D, perspective) are additive without breaking existing content.
/// The sim is projection-independent — this is a cosmetic, view-time transform only,
/// excluded from the state hash.
pub const Projection = union(enum) {
    /// Straight axis-aligned / top-down: world X→screen X and world Y→screen Y at a
    /// uniform pixels-per-world-unit `scale`; world Z is depth (higher draws in front).
    /// What a grid game like Snake wants.
    orthographic: Orthographic,
    /// Classic 2:1 isometric via `TileMetrics` — the original projection, unchanged.
    isometric: core.math.TileMetrics,

    /// Orthographic (top-down) parameters.
    pub const Orthographic = struct {
        /// Screen pixels per one world unit.
        scale: f32 = 32,
    };
};

/// Screen position and depth-sort key for one world point under `proj`. `origin` is
/// the screen pixel that world `(0,0,0)` maps to (typically the viewport centre).
/// Greater `depth` = nearer/front (drawn later, lands on top). Pure and total.
fn projectPoint(proj: Projection, pos: core.Vec3, origin: core.Vec2) struct { screen: core.Vec2, depth: f32 } {
    return switch (proj) {
        .orthographic => |o| .{
            .screen = .{ .x = origin.x + pos.x * o.scale, .y = origin.y + pos.y * o.scale },
            .depth = pos.z,
        },
        .isometric => |tile| .{
            .screen = core.math.worldToScreen(pos, tile, origin),
            .depth = pos.x + pos.y + pos.z,
        },
    };
}

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
    /// Projection-supplied depth key (greater = nearer/front): world `x + y + z` for
    /// isometric, world `z` for orthographic. Painter's algorithm submits ascending.
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

/// Project every entity transform in `world` into an NDC-space quad through
/// `view.projection`, then sort the result far-to-near by the projection's depth key
/// (greater = nearer) so the caller can submit quads in order and get correct
/// painter's-algorithm occlusion — nearer entities are drawn later and land on top.
/// The sort is stable and tie-breaks equal depth by entity index, so output order is
/// fully deterministic. The image origin is the screen centre. Caller owns the
/// returned slice. Pure/deterministic.
pub fn project(gpa: Allocator, world: *World, view: View, palette: []const [3]f32) Allocator.Error![]gpu.Quad {
    const half_w = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h = @as(f32, @floatFromInt(view.height)) / 2;
    const origin: core.Vec2 = .{ .x = half_w, .y = half_h };

    var entries: std.ArrayList(DepthEntry) = .empty;
    defer entries.deinit(gpa);
    for (world.transforms.entities(), world.transforms.slice()) |entity_index, t| {
        const p = projectPoint(view.projection, t.pos, origin);
        try entries.append(gpa, .{
            .quad = .{
                .center = .{ p.screen.x / half_w - 1, p.screen.y / half_h - 1 },
                .half = .{ view.quad_half_px / half_w, view.quad_half_px / half_h },
                .color = palette[entity_index % palette.len],
            },
            .depth = p.depth,
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

test "project: isometric — an entity at the origin maps to the NDC centre" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .isometric = .{ .half_w = 32, .half_h = 16, .z_height = 16 } } };
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

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .isometric = .{ .half_w = 32, .half_h = 16, .z_height = 16 } } };
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

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .isometric = .{ .half_w = 32, .half_h = 16, .z_height = 16 } } };
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

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .isometric = .{ .half_w = 32, .half_h = 16, .z_height = 16 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    try testing.expectEqual(@as(usize, 2), quads.len);
    try testing.expect(std.mem.eql(f32, &quads[0].color, &default_palette[a.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[1].color, &default_palette[b.index % default_palette.len]));
}

test "project: orthographic maps world axes straight to screen (identity/edge/negative)" {
    // Top-down: world X→screen X, world Y→screen Y at `scale` px/unit; no diamond.
    // 256x256 view, scale 32 → one world unit = 32px = 0.25 in NDC from centre.
    const Case = struct { pos: core.Vec3, want: [2]f32 };
    const cases = [_]Case{
        .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .want = .{ 0, 0 } }, // identity: origin → centre
        .{ .pos = .{ .x = 1, .y = 0, .z = 0 }, .want = .{ 0.25, 0 } }, // +X → screen right only
        .{ .pos = .{ .x = 0, .y = 1, .z = 0 }, .want = .{ 0, 0.25 } }, // +Y → screen down only
        .{ .pos = .{ .x = -2, .y = -1, .z = 0 }, .want = .{ -0.5, -0.25 } }, // negative both axes
        .{ .pos = .{ .x = 0, .y = 0, .z = 5 }, .want = .{ 0, 0 } }, // Z is depth only, not screen pos
    };
    for (cases) |c| {
        var world = World.init(testing.allocator);
        defer world.deinit();
        const e = try world.spawn();
        try world.setTransform(e, .{ .pos = c.pos });

        const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
        const quads = try project(testing.allocator, &world, view, &default_palette);
        defer testing.allocator.free(quads);

        try testing.expectApproxEqAbs(c.want[0], quads[0].center[0], 1e-6);
        try testing.expectApproxEqAbs(c.want[1], quads[0].center[1], 1e-6);
    }
}

test "project: orthographic sorts by world Z (higher draws in front)" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    // Spawn out of depth order; all share the ground XY, differing only in Z.
    const high = try world.spawn(); // z 3, entity index 0
    try world.setTransform(high, .{ .pos = .{ .x = 0, .y = 0, .z = 3 } });
    const low = try world.spawn(); // z 0, entity index 1
    try world.setTransform(low, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    const mid = try world.spawn(); // z 1, entity index 2
    try world.setTransform(mid, .{ .pos = .{ .x = 0, .y = 0, .z = 1 } });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    // Ascending depth (far→near): low → mid → high, so high lands on top.
    try testing.expectEqual(@as(usize, 3), quads.len);
    try testing.expect(std.mem.eql(f32, &quads[0].color, &default_palette[low.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[1].color, &default_palette[mid.index % default_palette.len]));
    try testing.expect(std.mem.eql(f32, &quads[2].color, &default_palette[high.index % default_palette.len]));
}
