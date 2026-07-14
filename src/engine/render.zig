//! Render preparation: turn a `World` into backend-ready draw data. This is the pure
//! (GPU-free, deterministic) half of rendering — it projects entity transforms to
//! NDC-space quads through a configurable camera projection (ADR 0014: isometric is
//! one view, not mandatory). The gpu backend rasterizes the result. Kept pure so it is
//! testable in CI without a GPU (ADR 0006 §6: rendering correctness of the projection
//! is guarded here; pixel output is verified out-of-band).

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const data = @import("data");
const sprite = @import("sprite.zig");
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
    /// Fallback quad half-size in pixels for an entity with no `Appearance` (ADR
    /// 0030) — unchanged legacy behavior. An entity that declares an `Appearance` is
    /// instead sized from its world-space `size` field × `pxPerWorldUnit`.
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

/// Screen pixels drawn per one world unit under `proj` (ADR 0030) — used to size an
/// appearance-declared quad in world space rather than fixed pixels, so an entity's
/// on-screen footprint scales with the projection instead of every entity drawing the
/// same size regardless of scale. Orthographic: exactly `scale`. Isometric: `half_w`,
/// the screen-space spread of one world-X unit — a pragmatic single scale for a square
/// footprint (the SVG/GPU emitters draw axis-aligned rects, not diamonds; a per-shape
/// emitter is a documented future follow-up, ADR 0029 §7).
fn pxPerWorldUnit(proj: Projection) f32 {
    return switch (proj) {
        .orthographic => |o| o.scale,
        .isometric => |tile| tile.half_w,
    };
}

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

/// Distinct colours cycled per entity so drawn quads are visually separable. Fallback
/// only: an entity with a declared `Appearance` (ADR 0030) uses its own color instead.
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
/// fully deterministic. The image origin is the screen centre.
///
/// Each entity's color, size, and shape come from its `Appearance` (ADR 0030) when
/// present: `Appearance.color` replaces the `palette` pick, `Appearance.size` (a
/// world-space footprint) is scaled by `pxPerWorldUnit(view.projection)` to size the
/// quad, and `Appearance.shape` carries straight through to `gpu.Quad.shape` — so a
/// wall on a one-unit grid cell fills its cell and a dot stays small and round,
/// regardless of the projection's pixel scale. An entity with no `Appearance` keeps
/// the legacy fallback: `palette[entity_index % palette.len]`, the fixed
/// `view.quad_half_px`, and `.rect`. An entity that carries a `Sprite` is skipped here
/// entirely — it is drawn by `projectSprites` as a textured quad, and emitting its flat
/// `Appearance` quad too would mask the sprite's transparent regions behind a solid box
/// (issue #121). Caller owns the returned slice. Pure/deterministic.
pub fn project(gpa: Allocator, world: *World, view: View, palette: []const [3]f32) Allocator.Error![]gpu.Quad {
    const half_w = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h = @as(f32, @floatFromInt(view.height)) / 2;
    const origin: core.Vec2 = .{ .x = half_w, .y = half_h };

    var entries: std.ArrayList(DepthEntry) = .empty;
    defer entries.deinit(gpa);
    for (world.transforms.entities(), world.transforms.slice()) |entity_index, t| {
        // An entity that carries a `Sprite` is drawn by `projectSprites` as a textured
        // quad, so it must NOT also emit this flat `Appearance` quad (issue #121): the
        // opaque flat quad would fill the sprite's transparent regions (Pac's mouth
        // wedge), masking the animation behind a solid box. The sprite's tint/size still
        // come from the `Appearance`; only the flat draw is suppressed.
        if (world.sprites.get(entity_index) != null) continue;
        const p = projectPoint(view.projection, t.pos, origin);
        const appearance = world.appearances.get(entity_index);
        const color = if (appearance) |a| a.color else palette[entity_index % palette.len];
        const half_px = if (appearance) |a| (a.size / 2) * pxPerWorldUnit(view.projection) else view.quad_half_px;
        const shape = if (appearance) |a| a.shape else .rect;
        try entries.append(gpa, .{
            .quad = .{
                .center = .{ p.screen.x / half_w - 1, p.screen.y / half_h - 1 },
                .half = .{ half_px / half_w, half_px / half_h },
                .color = color,
                .shape = shape,
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

/// A sprite quad plus its depth sort key, kept only for `projectSprites`'s sort.
const SpriteDepthEntry = struct {
    quad: gpu.SpriteQuad,
    depth: f32,
    entity_index: u32,
};

/// Ascending by depth (far to near), ties broken by entity index — the same painter's
/// order `project` uses, so sprites composite in the same front-to-back sense.
fn lessThanSpriteDepth(_: void, a: SpriteDepthEntry, b: SpriteDepthEntry) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    return a.entity_index < b.entity_index;
}

/// Project every `Sprite` entity in `world` into a textured `gpu.SpriteQuad` (issue #113
/// phase 2b; ADR 0031 §4): resolve the entity's current sheet frame (`AnimationState`'s
/// clip cursor → the clip's frame list → a sheet frame index), look that frame's UV
/// sub-rect up in `atlas`, and place the quad at the entity's projected screen footprint
/// (same centre/half-size math as `project`, `Appearance`-aware). The quad's `tint` is
/// the entity's `Appearance.color` (white if none), and its `angle` faces the entity's
/// travel direction — the screen-space direction of its `Velocity`, so a directional
/// sprite (Pac's wedge) turns to face where it moves; a stationary entity keeps `angle`
/// 0 (its default/right-facing pose). Results are painter-sorted far-to-near like
/// `project`. An entity whose sheet is unloaded, or whose current frame is not in the
/// atlas, is skipped and — since `project` suppresses the flat quad for any sprited
/// entity (issue #121) — draws nothing that frame rather than a masking box; a missing
/// sheet is a build error (`mise run assets`), not a runtime fallback. Pure and
/// deterministic; reads only cosmetic columns, never sim state. Caller owns the returned
/// slice. Errors: `error.OutOfMemory`.
pub fn projectSprites(
    gpa: Allocator,
    world: *World,
    view: View,
    store: *const sprite.SheetStore,
    atlas: *const sprite.Atlas,
) Allocator.Error![]gpu.SpriteQuad {
    const half_w = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h = @as(f32, @floatFromInt(view.height)) / 2;
    const origin: core.Vec2 = .{ .x = half_w, .y = half_h };

    var entries: std.ArrayList(SpriteDepthEntry) = .empty;
    defer entries.deinit(gpa);
    for (world.sprites.entities(), world.sprites.slice()) |entity_index, spr| {
        const t = world.transforms.get(entity_index) orelse continue;
        const sheet = store.get(spr.sheet) orelse continue;

        // Resolve the sheet frame the animation cursor currently points at: the clip's
        // frame list indexed by `AnimationState.frame` (its clip position), clamped so a
        // stale cursor after a clip swap can't read past the list. No/empty clip ⇒ the
        // sheet's frame 0.
        var sheet_frame: u16 = 0;
        if (sprite.findClip(sheet, spr.clip)) |clip| {
            if (clip.frames.len > 0) {
                const pos: usize = if (world.animations.get(entity_index)) |a|
                    @min(@as(usize, a.frame), clip.frames.len - 1)
                else
                    0;
                sheet_frame = clip.frames[pos];
            }
        }
        const region = atlas.uv(spr.sheet, sheet_frame) orelse continue;

        const p = projectPoint(view.projection, t.pos, origin);
        const appearance = world.appearances.get(entity_index);
        const half_px = if (appearance) |a| (a.size / 2) * pxPerWorldUnit(view.projection) else view.quad_half_px;
        const tint = if (appearance) |a| a.color else [3]f32{ 1, 1, 1 };

        // Face the travel direction: the screen-space angle of the velocity, found by
        // projecting a point one velocity-step ahead and taking the delta (works for any
        // projection). Zero velocity leaves the quad at angle 0 (its default pose).
        var angle: f32 = 0;
        if (world.velocities.get(entity_index)) |vel| {
            if (vel.v.x != 0 or vel.v.y != 0) {
                const ahead = projectPoint(view.projection, .{ .x = t.pos.x + vel.v.x, .y = t.pos.y + vel.v.y, .z = t.pos.z }, origin);
                angle = std.math.atan2(ahead.screen.y - p.screen.y, ahead.screen.x - p.screen.x);
            }
        }

        try entries.append(gpa, .{
            .quad = .{
                .center = .{ p.screen.x / half_w - 1, p.screen.y / half_h - 1 },
                .half = .{ half_px / half_w, half_px / half_h },
                .uv_min = region.min,
                .uv_max = region.max,
                .tint = tint,
                .angle = angle,
            },
            .depth = p.depth,
            .entity_index = entity_index,
        });
    }
    std.sort.block(SpriteDepthEntry, entries.items, {}, lessThanSpriteDepth);

    var quads: std.ArrayList(gpu.SpriteQuad) = .empty;
    errdefer quads.deinit(gpa);
    for (entries.items) |e| try quads.append(gpa, e.quad);
    return quads.toOwnedSlice(gpa);
}

const testing = std.testing;

/// Build a `SheetStore` owning one decoded sheet under `ref` (encode→decode so the store
/// owns freeable slices, matching `sprite.loadForScene`). Caller `deinit`s the store.
fn spriteStoreWith(gpa: Allocator, ref: []const u8, sheet: data.msf.Sheet) !sprite.SheetStore {
    const bytes = try data.msf.encode(gpa, sheet);
    defer gpa.free(bytes);
    const owned = try data.msf.decode(gpa, bytes);
    var store: sprite.SheetStore = .{ .gpa = gpa };
    try store.entries.append(gpa, .{ .ref = ref, .sheet = owned });
    return store;
}

test "projectSprites: places a textured quad and faces its velocity" {
    const gpa = testing.allocator;
    // A 2x2, single-frame sheet with a one-position clip.
    var px: [2 * 2 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 2,
        .height = 2,
        .frames = &.{&px},
        .clips = &.{.{ .name = "walk", .fps = 10, .frames = &.{0} }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setSprite(e, .{ .sheet = "s.msf", .clip = "walk" });
    try world.setVelocity(e, .{ .v = .{ .x = 0, .y = 1, .z = 0 } }); // moving +Y (screen-down)

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(quads);

    try testing.expectEqual(@as(usize, 1), quads.len);
    // Entity at the origin projects to the NDC centre.
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[1], 1e-6);
    // The single frame fills the whole atlas → full UV span.
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].uv_min[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), quads[0].uv_max[0], 1e-6);
    // +Y world velocity is screen-down under orthographic ⇒ angle +pi/2 (atan2(+dy, 0)).
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), quads[0].angle, 1e-5);
}

test "projectSprites → captureFrame: the animation cursor selects the frame rendered headlessly" {
    // The visibility guarantee (issue #122): the current chomp frame the null backend
    // composites headlessly is the one the animation cursor points at — so a broken sprite
    // shows up in a PNG + this test, not only when a user plays `--play`. Two distinct
    // frames (red, blue) prove the sampled texel — not a flat tint — reaches the target.
    const gpa = testing.allocator;
    var f0: [4 * 4 * 4]u8 = undefined; // opaque red
    var f1: [4 * 4 * 4]u8 = undefined; // opaque blue
    var p: usize = 0;
    while (p < f0.len) : (p += 4) {
        f0[p + 0] = 255;
        f0[p + 1] = 0;
        f0[p + 2] = 0;
        f0[p + 3] = 255;
        f1[p + 0] = 0;
        f1[p + 1] = 0;
        f1[p + 2] = 255;
        f1[p + 3] = 255;
    }
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 4,
        .height = 4,
        .frames = &.{ &f0, &f1 },
        .clips = &.{.{ .name = "chomp", .fps = 12, .frames = &.{ 0, 1 } }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(e, .{ .color = .{ 1, 1, 1 }, .size = 0.5 }); // fills the tiny frame
    try world.setSprite(e, .{ .sheet = "s.msf", .clip = "chomp" });
    try world.setVelocity(e, .{ .v = .{ .x = 1, .y = 0, .z = 0 } }); // face +x → angle 0, axis-aligned

    // view 16x16, scale 32 → size 0.5 ⇒ half 8px = NDC 1.0 (a full-frame quad).
    const view: View = .{ .width = 16, .height = 16, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const center = (8 * 16 + 8) * 4;

    // Frame 0 (clip position 0) → the red sheet frame fills the capture.
    try world.setAnimationState(e, .{ .frame = 0 });
    const q0 = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(q0);
    const px0 = try gpu.captureFrame(gpa, view.width, view.height, &.{}, q0, atlas.pixels, atlas.width, atlas.height, .{ 0, 0, 0, 1 });
    defer gpa.free(px0);
    try testing.expectEqual(@as(u8, 255), px0[center + 0]); // red
    try testing.expectEqual(@as(u8, 0), px0[center + 2]);

    // Frame 1 (clip position 1) → the blue sheet frame — the cursor changed the output.
    try world.setAnimationState(e, .{ .frame = 1 });
    const q1 = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(q1);
    const px1 = try gpu.captureFrame(gpa, view.width, view.height, &.{}, q1, atlas.pixels, atlas.width, atlas.height, .{ 0, 0, 0, 1 });
    defer gpa.free(px1);
    try testing.expectEqual(@as(u8, 0), px1[center + 0]);
    try testing.expectEqual(@as(u8, 255), px1[center + 2]); // blue
}

test "projectSprites: a stationary entity keeps angle 0; an unloaded sheet is skipped" {
    const gpa = testing.allocator;
    var px: [1 * 1 * 4]u8 = .{ 9, 9, 9, 255 };
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "idle", .fps = 1, .frames = &.{0} }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    // Stationary sprited entity (no velocity component).
    const still = try world.spawn();
    try world.setTransform(still, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setSprite(still, .{ .sheet = "s.msf", .clip = "idle" });
    // A second entity references a sheet absent from the store → no sprite quad.
    const absent = try world.spawn();
    try world.setTransform(absent, .{ .pos = .{ .x = 1, .y = 0, .z = 0 } });
    try world.setSprite(absent, .{ .sheet = "absent.msf", .clip = "idle" });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(quads);

    // Only the loaded, stationary entity yields a quad, at angle 0.
    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].angle, 1e-6);
}

test "project: an entity with a Sprite emits no flat quad (issue #121 — the box is suppressed)" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    // A sprited entity (like pac): it carries an Appearance for tint/size AND a Sprite.
    // Only `projectSprites` should draw it; `project` must not add a flat masking quad.
    const sprited = try world.spawn();
    try world.setTransform(sprited, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(sprited, .{ .color = .{ 1, 0.9, 0.2 }, .size = 0.7, .shape = .circle });
    try world.setSprite(sprited, .{ .sheet = "sprites/pac.msf", .clip = "chomp" });
    // A plain entity alongside it still gets its flat quad, proving suppression is scoped.
    const plain = try world.spawn();
    try world.setTransform(plain, .{ .pos = .{ .x = 1, .y = 0, .z = 0 } });
    try world.setAppearance(plain, .{ .color = .{ 0.2, 0.2, 0.2 }, .size = 1 });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    // Exactly one flat quad — the plain entity's; the sprited entity was skipped.
    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expect(std.mem.eql(f32, &.{ 0.2, 0.2, 0.2 }, &quads[0].color));
}

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

test "project: an entity with an Appearance uses its color, not the palette" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(e, .{ .color = .{ 0.1, 0.2, 0.3 } });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    try testing.expect(std.mem.eql(f32, &.{ 0.1, 0.2, 0.3 }, &quads[0].color));
    // Not the palette's index-0 fallback colour.
    try testing.expect(!std.mem.eql(f32, &default_palette[0], &quads[0].color));
}

test "project: an entity's Appearance.size scales the quad by world-scale, not view.quad_half_px" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const with_appearance = try world.spawn();
    try world.setTransform(with_appearance, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(with_appearance, .{ .color = .{ 1, 1, 1 }, .size = 1 }); // 1 world unit wide
    const without_appearance = try world.spawn();
    try world.setTransform(without_appearance, .{ .pos = .{ .x = 5, .y = 5, .z = 0 } });

    // scale = 24px/unit ⇒ Appearance.size=1 ⇒ half-extent 12px, not the 16px default.
    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 24 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    const half_w: f32 = 128;
    try testing.expectApproxEqAbs(@as(f32, 12.0 / 128.0), quads[0].half[0], 1e-6);
    // The appearance-less entity keeps the legacy fixed 16px half-extent.
    try testing.expectApproxEqAbs(view.quad_half_px / half_w, quads[1].half[0], 1e-6);
}

test "project: pxPerWorldUnit uses half_w under isometric to scale an Appearance quad" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(e, .{ .color = .{ 1, 1, 1 }, .size = 2 }); // 2 world units wide

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .isometric = .{ .half_w = 32, .half_h = 16, .z_height = 16 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    // half-extent = (size/2) * half_w = 1 * 32 = 32px.
    try testing.expectApproxEqAbs(@as(f32, 32.0 / 128.0), quads[0].half[0], 1e-6);
}

test "project: an entity's Appearance.shape carries through to the quad; absent Appearance defaults to rect" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const circle = try world.spawn();
    try world.setTransform(circle, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setAppearance(circle, .{ .color = .{ 1, 1, 1 }, .shape = .circle });
    const default_rect = try world.spawn();
    try world.setTransform(default_rect, .{ .pos = .{ .x = 1, .y = 0, .z = 0 } });
    try world.setAppearance(default_rect, .{ .color = .{ 1, 1, 1 } }); // shape omitted
    const no_appearance = try world.spawn();
    try world.setTransform(no_appearance, .{ .pos = .{ .x = 2, .y = 0, .z = 0 } });

    const view: View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try project(testing.allocator, &world, view, &default_palette);
    defer testing.allocator.free(quads);

    try testing.expectEqual(gpu.Shape.circle, quads[0].shape);
    try testing.expectEqual(gpu.Shape.rect, quads[1].shape);
    try testing.expectEqual(gpu.Shape.rect, quads[2].shape);
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
