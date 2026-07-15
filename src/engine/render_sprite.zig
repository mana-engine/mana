//! Textured sprite-quad projection, split out of `render.zig` (issue #151; the parent
//! file crossed the ~500-line soft limit once this path grew its own depth-sort/frame-
//! resolution logic and test suite). Cohesive on its own: it turns each `Sprite` entity
//! into one atlas-backed `gpu.SpriteQuad`, whereas `render.zig` projects the flat
//! `Appearance`-only quad path. Shares `render.zig`'s projection math (`View`,
//! `Projection`, `projectPoint`, `screenFacing`, `pxPerWorldUnit`) rather than
//! duplicating it. Re-exported as `render.projectSprites` so the public API is
//! unchanged. Pure/GPU-free like its sibling — see `render.zig`'s header for the
//! determinism rationale.

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const data = @import("data");
const sprite = @import("sprite.zig");
const render = @import("render.zig");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// A sprite quad plus its depth sort key, kept only for `projectSprites`'s sort.
const SpriteDepthEntry = struct {
    quad: gpu.SpriteQuad,
    depth: f32,
    entity_index: u32,
};

/// Ascending by depth (far to near), ties broken by entity index — the same painter's
/// order `render.project` uses, so sprites composite in the same front-to-back sense.
fn lessThanSpriteDepth(_: void, a: SpriteDepthEntry, b: SpriteDepthEntry) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    return a.entity_index < b.entity_index;
}

/// Which sheet frame (and horizontal mirror) entity `entity_index`'s sprite should draw
/// this call (ADR 0033): classify its latched `AnimationState.heading` into a screen
/// facing (`render.screenFacing`), select that facing's phase list
/// (`sprite.resolveFacing`, mirroring a missing horizontal facing from its opposite), then
/// index it by the animation cursor (`AnimationState.frame`), clamped so a stale cursor
/// can't read past the list. No matching clip in `sheet`, or an empty phase list, yields
/// sheet frame 0. Pure.
fn resolveSpriteFrame(
    world: *World,
    entity_index: u32,
    sheet: *const data.msf.Sheet,
    clip_name: []const u8,
    proj: render.Projection,
    origin: core.Vec2,
) struct { sheet_frame: u16, mirror_x: bool } {
    const clip = sprite.findClip(sheet, clip_name) orelse return .{ .sheet_frame = 0, .mirror_x = false };
    const heading = if (world.animations.get(entity_index)) |a| a.heading else core.Vec2{ .x = 0, .y = 0 };
    const resolved = sprite.resolveFacing(clip, render.screenFacing(proj, heading, origin));
    var sheet_frame: u16 = 0;
    if (resolved.frames.len > 0) {
        const pos: usize = if (world.animations.get(entity_index)) |a|
            @min(@as(usize, a.frame), resolved.frames.len - 1)
        else
            0;
        sheet_frame = resolved.frames[pos];
    }
    return .{ .sheet_frame = sheet_frame, .mirror_x = resolved.mirror_x };
}

/// Project every `Sprite` entity in `world` into a textured `gpu.SpriteQuad` (issue #113
/// phase 2b; ADR 0031 §4, ADR 0033): resolve the entity's current sheet frame
/// (`resolveSpriteFrame`), look that frame's UV sub-rect up in `atlas`, and place the quad
/// at the entity's projected screen footprint (same centre/half-size math as
/// `render.project`, `Appearance`-aware). The quad's `tint` is the entity's resolved
/// `TintCue` cursor color (issue #128) when active, else `Appearance.color` (white if
/// neither); an inferred (mirrored) facing X-flips the frame's UV (a CPU-side U swap, no
/// shader change). Sprite quads are axis-aligned — facing is a frame choice, not a
/// rotation (ADR 0033 retired the wedge-rotation hack). Results are painter-sorted
/// far-to-near like `render.project`. An entity whose sheet is unloaded, or whose current
/// frame is not in the atlas, is skipped here — and because `render.project` suppresses
/// the flat quad only for a sprite that DOES draw (issue #121), such an entity still gets
/// its flat `Appearance` quad from `render.project` and stays visible (a box), rather than
/// vanishing. A missing sheet is a content/setup issue the sheet loader already warns
/// about at load (`mise run assets` regenerates it); it is not fatal. Pure and
/// deterministic; reads only cosmetic columns, never sim state. Caller owns the returned
/// slice. Errors: `error.OutOfMemory`.
pub fn projectSprites(
    gpa: Allocator,
    world: *World,
    view: render.View,
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

        const fr = resolveSpriteFrame(world, entity_index, sheet, spr.clip, view.projection, origin);
        const region = atlas.uv(spr.sheet, fr.sheet_frame) orelse continue;

        const p = render.projectPoint(view.projection, t.pos, origin);
        const appearance = world.appearances.get(entity_index);
        const half_px = if (appearance) |a| (a.size / 2) * render.pxPerWorldUnit(view.projection) else view.quad_half_px;
        // A `TintCue`'s resolved cursor color (issue #128) overrides `Appearance.color`/
        // white when present — the same precedence `render.project` applies to the flat-
        // quad path, so a sprited entity's frightened-blue/blink/flash cue works
        // identically.
        const tint_override = if (world.tint_cursors.get(entity_index)) |tc| tc.color else null;
        const tint = tint_override orelse (if (appearance) |a| a.color else [3]f32{ 1, 1, 1 });

        // Mirror an inferred facing by swapping the frame's U endpoints: the vertex builder
        // interpolates U linearly across the quad, so the sampled frame is X-flipped with
        // no shader change (ADR 0033 §2). V (the vertical axis) is untouched.
        var uv_min = region.min;
        var uv_max = region.max;
        if (fr.mirror_x) std.mem.swap(f32, &uv_min[0], &uv_max[0]);

        try entries.append(gpa, .{
            .quad = .{
                .center = .{ p.screen.x / half_w - 1, p.screen.y / half_h - 1 },
                .half = .{ half_px / half_w, half_px / half_h },
                .uv_min = uv_min,
                .uv_max = uv_max,
                .tint = tint,
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

test "projectSprites: places a textured quad at the projected footprint" {
    const gpa = testing.allocator;
    // A 2x2, single-frame non-directional clip (no facings).
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

    const view: render.View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(quads);

    try testing.expectEqual(@as(usize, 1), quads.len);
    // Entity at the origin projects to the NDC centre.
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].center[1], 1e-6);
    // The single frame fills the whole atlas → full UV span, unmirrored (uv_min < uv_max).
    try testing.expectApproxEqAbs(@as(f32, 0), quads[0].uv_min[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), quads[0].uv_max[0], 1e-6);
}

test "projectSprites: a directional clip selects the frame for the latched facing" {
    const gpa = testing.allocator;
    // Four distinct 1x1 frames: 0=right, 1=down, 2=up (left inferred from right).
    var f_right = [_]u8{ 10, 0, 0, 255 };
    var f_down = [_]u8{ 0, 20, 0, 255 };
    var f_up = [_]u8{ 0, 0, 30, 255 };
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{ &f_right, &f_down, &f_up },
        .clips = &.{.{
            .name = "chomp",
            .fps = 10,
            .frames = &.{0}, // base = right
            .facings = .{ &.{2}, &.{1}, null, &.{0} }, // up, down, left(absent), right
        }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setSprite(e, .{ .sheet = "s.msf", .clip = "chomp" });
    const view: render.View = .{ .width = 16, .height = 16, .projection = .{ .orthographic = .{ .scale = 32 } } };

    // A helper: the atlas UV for a given sheet frame, so we can assert which frame drew.
    const uvFor = struct {
        fn f(a: *const sprite.Atlas, frame: u16) [2]f32 {
            return a.uv("s.msf", frame).?.min;
        }
    }.f;

    // Heading up (world −Y = screen up) → the up facing → frame 2, no mirror.
    try world.setAnimationState(e, .{ .heading = .{ .x = 0, .y = -1 } });
    const up = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(up);
    try testing.expectApproxEqAbs(uvFor(&atlas, 2)[0], up[0].uv_min[0], 1e-6);
    try testing.expect(up[0].uv_min[0] <= up[0].uv_max[0]); // not mirrored

    // Heading down (world +Y) → the down facing → frame 1.
    try world.setAnimationState(e, .{ .heading = .{ .x = 0, .y = 1 } });
    const down = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(down);
    try testing.expectApproxEqAbs(uvFor(&atlas, 1)[0], down[0].uv_min[0], 1e-6);
}

test "projectSprites: a missing horizontal facing is X-flipped from its opposite (mirror rule)" {
    const gpa = testing.allocator;
    // Right authored, left absent ⇒ heading left renders right's frame with swapped U.
    var f_right = [_]u8{ 10, 0, 0, 255 };
    var f_down = [_]u8{ 0, 20, 0, 255 };
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{ &f_right, &f_down },
        .clips = &.{.{
            .name = "chomp",
            .fps = 10,
            .frames = &.{0},
            .facings = .{ null, &.{1}, null, &.{0} }, // up(absent), down, left(absent), right
        }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setSprite(e, .{ .sheet = "s.msf", .clip = "chomp" });
    const view: render.View = .{ .width = 16, .height = 16, .projection = .{ .orthographic = .{ .scale = 32 } } };

    const right_uv = atlas.uv("s.msf", 0).?;

    // Heading right → right's frame, unmirrored: uv_min.u < uv_max.u.
    try world.setAnimationState(e, .{ .heading = .{ .x = 1, .y = 0 } });
    const r = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(r);
    try testing.expectApproxEqAbs(right_uv.min[0], r[0].uv_min[0], 1e-6);
    try testing.expectApproxEqAbs(right_uv.max[0], r[0].uv_max[0], 1e-6);

    // Heading left → SAME frame (right's), but U endpoints swapped ⇒ X-flip. V unchanged.
    try world.setAnimationState(e, .{ .heading = .{ .x = -1, .y = 0 } });
    const l = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(l);
    try testing.expectApproxEqAbs(right_uv.max[0], l[0].uv_min[0], 1e-6); // swapped
    try testing.expectApproxEqAbs(right_uv.min[0], l[0].uv_max[0], 1e-6);
    try testing.expectApproxEqAbs(right_uv.min[1], l[0].uv_min[1], 1e-6); // V untouched
}

test "projectSprites → advance: the latched heading holds facing across a momentary stop (no flip, #125)" {
    const gpa = testing.allocator;
    var f_right = [_]u8{ 10, 0, 0, 255 };
    var f_down = [_]u8{ 0, 20, 0, 255 };
    var store = try spriteStoreWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{ &f_right, &f_down },
        .clips = &.{.{
            .name = "chomp",
            .fps = 10,
            .frames = &.{0},
            .facings = .{ null, &.{1}, null, &.{0} }, // down + right authored
        }},
    });
    defer store.deinit();
    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var world = World.init(gpa);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try world.setSprite(e, .{ .sheet = "s.msf", .clip = "chomp" });
    const view: render.View = .{ .width = 16, .height = 16, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const down_uv = atlas.uv("s.msf", 1).?.min[0];

    // Move down: advance latches the heading, so the down facing (frame 1) is chosen.
    try world.setVelocity(e, .{ .v = .{ .x = 0, .y = 1, .z = 0 } });
    sprite.advance(&world, &store, 0.05);
    const moving = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(moving);
    try testing.expectApproxEqAbs(down_uv, moving[0].uv_min[0], 1e-6);

    // Momentary stop at an intersection: velocity 0 for a frame. The latch RETAINS the
    // down heading, so the facing does NOT flip back to the default pose (#125 fixed).
    try world.setVelocity(e, .{ .v = .{ .x = 0, .y = 0, .z = 0 } });
    sprite.advance(&world, &store, 0.05);
    const stopped = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(stopped);
    try testing.expectApproxEqAbs(down_uv, stopped[0].uv_min[0], 1e-6);
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
    // Non-directional clip (no facings) + zero heading ⇒ the base frame list is used.

    // view 16x16, scale 32 → size 0.5 ⇒ half 8px = NDC 1.0 (a full-frame quad).
    const view: render.View = .{ .width = 16, .height = 16, .projection = .{ .orthographic = .{ .scale = 32 } } };
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

test "projectSprites: a loaded stationary entity yields one quad; an unloaded sheet is skipped" {
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

    const view: render.View = .{ .width = 256, .height = 256, .projection = .{ .orthographic = .{ .scale = 32 } } };
    const quads = try projectSprites(gpa, &world, view, &store, &atlas);
    defer gpa.free(quads);

    // Only the loaded, stationary entity yields a quad (non-directional, unmirrored).
    try testing.expectEqual(@as(usize, 1), quads.len);
    try testing.expect(quads[0].uv_min[0] <= quads[0].uv_max[0]);
}
