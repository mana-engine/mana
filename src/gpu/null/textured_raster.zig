//! CPU textured-triangle rasterizer for the null gpu backend (ADR 0031 §4; Issue #122).
//! Extracted from `backend.zig` so the backend adapter stays navigable: this file is the
//! pure pixel math — nearest-neighbour atlas sample + straight-alpha "over" blend — unit-
//! tested here, while `backend.zig` wires `rasterTri` into the `CommandList` textured-draw
//! path. It is a REAL texel sampler, the null backend's headless test double for the Vulkan
//! textured pipeline: it mirrors `sprite.wgsl` (`rgb·tint`, alpha passthrough) and the
//! Vulkan src-alpha-over blend, so a `render.projectSprites` geometry/UV bug reproduces
//! headlessly (pixel-for-pixel modulo the shared-diagonal seam — a deterministic
//! test-double artifact; a top-left fill rule is unneeded). No Vulkan, pure host math.

const std = @import("std");
const port = @import("../port.zig");

/// Rasterize one textured triangle (`a`,`b`,`c`, in `port.TexturedVertex`) into `target`
/// (tightly-packed RGBA8, `tw`×`th`), sampling `atlas` (RGBA8, `aw`×`ah`). Walks the
/// triangle's pixel bounding box, keeps fragments whose centre is inside (barycentric
/// coords all ≥ 0, winding-agnostic), interpolates the UV there, samples the atlas
/// nearest-neighbour, tints RGB and straight-alpha "over"-blends the texel onto `target`.
/// Tint is taken from `a` (the vertex builder gives all three corners the same tint).
/// `target`/`atlas` are borrowed for the call; the caller guarantees non-zero dimensions.
pub fn rasterTri(
    target: []u8,
    tw: u32,
    th: u32,
    atlas: []const u8,
    aw: u32,
    ah: u32,
    a: port.TexturedVertex,
    b: port.TexturedVertex,
    c: port.TexturedVertex,
) void {
    const ax = ndcToPxF(a.x, tw);
    const ay = ndcToPxF(a.y, th);
    const bx = ndcToPxF(b.x, tw);
    const by = ndcToPxF(b.y, th);
    const cx = ndcToPxF(c.x, tw);
    const cy = ndcToPxF(c.y, th);

    const denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
    if (denom == 0) return; // degenerate (zero-area) triangle
    const inv = 1.0 / denom;

    const x0 = clampPx(@intFromFloat(@floor(@min(ax, @min(bx, cx)))), tw);
    const x1 = clampPx(@intFromFloat(@ceil(@max(ax, @max(bx, cx)))), tw);
    const y0 = clampPx(@intFromFloat(@floor(@min(ay, @min(by, cy)))), th);
    const y1 = clampPx(@intFromFloat(@ceil(@max(ay, @max(by, cy)))), th);
    const tint = [3]f32{ a.r, a.g, a.b };

    var py = y0;
    while (py < y1) : (py += 1) {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        var px = x0;
        while (px < x1) : (px += 1) {
            const sx = @as(f32, @floatFromInt(px)) + 0.5;
            const l0 = ((by - cy) * (sx - cx) + (cx - bx) * (sy - cy)) * inv;
            const l1 = ((cy - ay) * (sx - cx) + (ax - cx) * (sy - cy)) * inv;
            const l2 = 1.0 - l0 - l1;
            if (l0 < 0 or l1 < 0 or l2 < 0) continue;
            const u = l0 * a.u + l1 * b.u + l2 * c.u;
            const v = l0 * a.v + l1 * b.v + l2 * c.v;
            blendTexel(target, tw, atlas, aw, ah, px, py, u, v, tint);
        }
    }
}

/// Sample `atlas` (RGBA8, `aw`×`ah`) at UV (`u`,`v`) nearest-neighbour, tint its RGB, and
/// straight-alpha "over"-blend it onto `target` (RGBA8, row stride `tw`) pixel (`px`,`py`):
/// `out = src·a + dst·(1−a)` for colour and `a + dst_a·(1−a)` for alpha — matching
/// `sprite.wgsl` (`rgb·tint`, alpha passthrough) and the Vulkan src-alpha-over blend.
/// `px`/`py` are in bounds (the caller clamps).
fn blendTexel(target: []u8, tw: u32, atlas: []const u8, aw: u32, ah: u32, px: u32, py: u32, u: f32, v: f32, tint: [3]f32) void {
    const s = (@as(usize, sampleAxis(v, ah)) * aw + sampleAxis(u, aw)) * 4;
    const sa = @as(f32, @floatFromInt(atlas[s + 3])) / 255.0;
    const sr = @as(f32, @floatFromInt(atlas[s + 0])) / 255.0 * tint[0];
    const sg = @as(f32, @floatFromInt(atlas[s + 1])) / 255.0 * tint[1];
    const sb = @as(f32, @floatFromInt(atlas[s + 2])) / 255.0 * tint[2];

    const d = (@as(usize, py) * tw + px) * 4;
    const dr = @as(f32, @floatFromInt(target[d + 0])) / 255.0;
    const dg = @as(f32, @floatFromInt(target[d + 1])) / 255.0;
    const db = @as(f32, @floatFromInt(target[d + 2])) / 255.0;
    const da = @as(f32, @floatFromInt(target[d + 3])) / 255.0;

    target[d + 0] = toU8(sr * sa + dr * (1 - sa));
    target[d + 1] = toU8(sg * sa + dg * (1 - sa));
    target[d + 2] = toU8(sb * sa + db * (1 - sa));
    target[d + 3] = toU8(sa + da * (1 - sa));
}

/// NDC coordinate `ndc` (−1..1) to a continuous pixel coordinate on a `dim`-wide axis; y
/// increases downward, matching the framebuffer and the flat rasterizer's `ndcToPx`.
fn ndcToPxF(ndc: f32, dim: u32) f32 {
    return (ndc + 1) * 0.5 * @as(f32, @floatFromInt(dim));
}

/// Nearest-neighbour texel index for atlas UV `coord` on a `dim`-texel axis: `floor(coord *
/// dim)` clamped to `[0, dim)` — the clamp-to-edge nearest filter the Vulkan sampler uses.
fn sampleAxis(coord: f32, dim: u32) u32 {
    const t: i64 = @intFromFloat(@floor(coord * @as(f32, @floatFromInt(dim))));
    return @intCast(std.math.clamp(t, 0, @as(i64, dim) - 1));
}

/// Round a 0..1 float colour to a u8, clamped — the RGBA8 write helper.
fn toU8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// Clamp a pixel coordinate to `[0, dim]` (an exclusive upper bound for a `< dim` loop).
fn clampPx(px: i64, dim: u32) u32 {
    return @intCast(std.math.clamp(px, 0, @as(i64, dim)));
}

const testing = std.testing;

/// The 6 textured vertices (two triangles, TL,TR,BL, BL,TR,BR) of a full-frame quad
/// spanning the whole atlas UV, tinted `tint` — the exact layout `buildTexturedVertices`
/// emits, so `rasterTri` is tested against real draw geometry.
fn fullFrameQuad(tint: [3]f32) [6]port.TexturedVertex {
    return .{
        .{ .x = -1, .y = -1, .u = 0, .v = 0, .r = tint[0], .g = tint[1], .b = tint[2] }, // TL
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = tint[0], .g = tint[1], .b = tint[2] }, // TR
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = tint[0], .g = tint[1], .b = tint[2] }, // BL
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = tint[0], .g = tint[1], .b = tint[2] }, // BL
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = tint[0], .g = tint[1], .b = tint[2] }, // TR
        .{ .x = 1, .y = 1, .u = 1, .v = 1, .r = tint[0], .g = tint[1], .b = tint[2] }, // BR
    };
}

test "textured raster: samples the atlas nearest-neighbour and alpha-blends over the target" {
    // 8x8 target pre-filled opaque blue; a 2x1 atlas: left opaque red, right 50%-alpha green.
    var target: [8 * 8 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < target.len) : (i += 4) {
        target[i + 0] = 0;
        target[i + 1] = 0;
        target[i + 2] = 255;
        target[i + 3] = 255;
    }
    const atlas = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const q = fullFrameQuad(.{ 1, 1, 1 });
    rasterTri(&target, 8, 8, &atlas, 2, 1, q[0], q[1], q[2]);
    rasterTri(&target, 8, 8, &atlas, 2, 1, q[3], q[4], q[5]);

    // Left half (u<0.5) samples the opaque red texel → red covers the blue clear.
    const left = (4 * 8 + 1) * 4;
    try testing.expectEqual(@as(u8, 255), target[left + 0]);
    try testing.expectEqual(@as(u8, 0), target[left + 1]);
    try testing.expectEqual(@as(u8, 0), target[left + 2]);
    // Right half (u≥0.5) samples the 50%-alpha green texel: it blends over the blue clear —
    // proof of real texel sampling AND alpha compositing (not a flat fill).
    const right = (4 * 8 + 6) * 4;
    try testing.expectEqual(@as(u8, 0), target[right + 0]); // no red
    try testing.expectEqual(@as(u8, 128), target[right + 1]); // 0.502·green
    try testing.expectEqual(@as(u8, 127), target[right + 2]); // 0.498·blue shows through
}

test "textured raster: the tint multiplies the sampled texel" {
    // 4x4 target over opaque black; a 1x1 opaque-white atlas, tinted (1, 0.5, 0.25).
    var target = [_]u8{0} ** (4 * 4 * 4);
    var i: usize = 3;
    while (i < target.len) : (i += 4) target[i] = 255; // opaque
    const atlas = [_]u8{ 255, 255, 255, 255 };
    const q = fullFrameQuad(.{ 1, 0.5, 0.25 });
    rasterTri(&target, 4, 4, &atlas, 1, 1, q[0], q[1], q[2]);
    rasterTri(&target, 4, 4, &atlas, 1, 1, q[3], q[4], q[5]);

    const p = (2 * 4 + 2) * 4;
    try testing.expectEqual(@as(u8, 255), target[p + 0]); // 1·255
    try testing.expectEqual(@as(u8, 128), target[p + 1]); // 0.5·255
    try testing.expectEqual(@as(u8, 64), target[p + 2]); // 0.25·255
}
