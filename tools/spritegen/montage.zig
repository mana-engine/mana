//! Builds the human-viewable preview (ADR 0031 §3): every sprite frame composited
//! over a checkerboard (so transparency reads) and laid out in a single row with a
//! gutter. Returns an opaque RGBA8 image the caller encodes to PNG via `data.png`.
//! Pure and deterministic (no time, no RNG); the preview is a DERIVED, gitignored
//! artifact, never committed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An assembled preview image: opaque RGBA8, row-major top-to-bottom.
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.rgba);
        self.* = undefined;
    }
};

/// Gutter (px) between frames and around the border.
const gutter = 4;
/// Checkerboard cell size (px).
const check = 6;

/// Lay `frames` (each `size`×`size` straight-alpha RGBA8) out in one row over a
/// checkerboard. Caller owns the returned image; free with `Image.deinit`.
pub fn build(gpa: Allocator, size: u32, frames: []const []const u8) Allocator.Error!Image {
    const n: u32 = @intCast(frames.len);
    const width = gutter + n * (size + gutter);
    const height = 2 * gutter + size;
    var rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    fillCheckerboard(rgba, width, height);

    // Composite each frame (straight-alpha over) at its slot.
    for (frames, 0..) |frame, i| {
        const ox = gutter + @as(u32, @intCast(i)) * (size + gutter);
        const oy = gutter;
        var fy: u32 = 0;
        while (fy < size) : (fy += 1) {
            var fx: u32 = 0;
            while (fx < size) : (fx += 1) {
                const src = frame[(@as(usize, fy) * size + fx) * 4 ..][0..4];
                const a: u32 = src[3];
                if (a == 0) continue;
                const dst_idx = (@as(usize, oy + fy) * width + (ox + fx)) * 4;
                const dst = rgba[dst_idx..][0..4];
                dst[0] = over(src[0], dst[0], a);
                dst[1] = over(src[1], dst[1], a);
                dst[2] = over(src[2], dst[2], a);
                // dst stays opaque (a == 255) — the checkerboard is the opaque base.
            }
        }
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

/// Fill `rgba` (`width`×`height` RGBA8) with the opaque checkerboard pattern `build` uses
/// as its transparency-reading backdrop. Shared with `compositeOverCheckerboard` so both
/// callers get the identical board.
fn fillCheckerboard(rgba: []u8, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = (@as(usize, y) * width + x) * 4;
            const shade: u8 = if (((x / check) + (y / check)) % 2 == 0) 0x50 else 0x38;
            rgba[idx + 0] = shade;
            rgba[idx + 1] = shade;
            rgba[idx + 2] = shade;
            rgba[idx + 3] = 0xff;
        }
    }
}

/// Composite an already-rendered straight-alpha-over-transparent RGBA8 image (as
/// `gpu.captureFrame` returns when called with a fully transparent `clear`) over a fresh
/// checkerboard backdrop, so its transparency reads (ADR 0031 §3's montage idea, extended
/// for issue #129's headless MSF previewer: a `captureFrame` render composited for human
/// viewing, not just `build`'s raw per-frame montage). `rgba` is `width`×`height`; a fully
/// transparent source pixel (`a == 0`) leaves the checkerboard showing through unchanged.
/// Because `captureFrame`'s "over" blend onto a transparent (all-zero) clear leaves the
/// colour channels alpha-weighted (`straight * a`, not divided back out), a partially
/// transparent source pixel is un-premultiplied (`unpremultiply`) before the same `over`
/// blend `build` uses — otherwise an anti-aliased edge would be double-darkened. Caller
/// owns the returned image; free with `Image.deinit`.
pub fn compositeOverCheckerboard(gpa: Allocator, width: u32, height: u32, rgba: []const u8) Allocator.Error!Image {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    var out = try gpa.alloc(u8, rgba.len);
    fillCheckerboard(out, width, height);

    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0) continue; // fully transparent: checkerboard shows through unchanged
        const sr = unpremultiply(rgba[i + 0], a);
        const sg = unpremultiply(rgba[i + 1], a);
        const sb = unpremultiply(rgba[i + 2], a);
        out[i + 0] = over(sr, out[i + 0], a);
        out[i + 1] = over(sg, out[i + 1], a);
        out[i + 2] = over(sb, out[i + 2], a);
        // out[i+3] stays 255 — the checkerboard is the opaque base, matching `build`.
    }
    return .{ .width = width, .height = height, .rgba = out };
}

/// Recover a straight-alpha 8-bit channel from `premul` (`straight * a / 255`, the form
/// `gpu.captureFrame`'s "over" blend leaves when composited onto a transparent clear) given
/// alpha `a` (1..255; `a == 0` is never called, see `compositeOverCheckerboard`).
fn unpremultiply(premul: u8, a: u32) u8 {
    const v = (@as(u32, premul) * 255 + a / 2) / a;
    return @intCast(@min(v, 255));
}

/// Straight-alpha source-over of an 8-bit `src` with alpha `a` (0..255) onto opaque
/// `dst`: `(src*a + dst*(255-a)) / 255`, rounded.
fn over(src: u8, dst: u8, a: u32) u8 {
    const s: u32 = src;
    const d: u32 = dst;
    return @intCast((s * a + d * (255 - a) + 127) / 255);
}

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "montage: lays frames in a row with gutters, opaque output" {
    const size: u32 = 4;
    var f0 = [_]u8{0} ** (size * size * 4);
    // A fully-opaque red frame.
    var i: usize = 0;
    while (i < f0.len) : (i += 4) {
        f0[i] = 255;
        f0[i + 3] = 255;
    }
    const frames = [_][]const u8{ &f0, &f0 };
    var img = try build(testing.allocator, size, &frames);
    defer img.deinit(testing.allocator);

    try testing.expectEqual(gutter + 2 * (size + gutter), img.width);
    try testing.expectEqual(2 * gutter + size, img.height);
    // Every output pixel is opaque (checkerboard base + opaque frames).
    var p: usize = 3;
    while (p < img.rgba.len) : (p += 4) try testing.expectEqual(@as(u8, 255), img.rgba[p]);
    // A pixel inside the first frame slot is red (the frame composited over the board).
    const cx = gutter + 1;
    const cy = gutter + 1;
    const idx = (cy * img.width + cx) * 4;
    try testing.expectEqual(@as(u8, 255), img.rgba[idx]);
}

test "montage: compositeOverCheckerboard passes an opaque pixel through unchanged" {
    // A 1x1 fully-opaque red "capture" (as if `gpu.captureFrame` drew one opaque texel).
    const rgba = [_]u8{ 255, 0, 0, 255 };
    var img = try compositeOverCheckerboard(testing.allocator, 1, 1, &rgba);
    defer img.deinit(testing.allocator);
    // Opaque source ⇒ un-premultiply is a no-op and `over` yields the source exactly,
    // regardless of which checkerboard cell underlies it.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba);
}

test "montage: compositeOverCheckerboard leaves a fully transparent pixel as the checkerboard" {
    const rgba = [_]u8{ 0, 0, 0, 0 };
    var img = try compositeOverCheckerboard(testing.allocator, 1, 1, &rgba);
    defer img.deinit(testing.allocator);
    // (0,0) is checkerboard cell (0,0) ⇒ the first `shade` (0x50), opaque.
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x50, 0x50, 0xff }, img.rgba);
}

test "montage: compositeOverCheckerboard un-premultiplies a partially transparent pixel before blending" {
    // A 50%-alpha red source, premultiplied as `gpu.captureFrame` would leave it over a
    // transparent clear: straight red (255,0,0) * alpha(128/255) ≈ (128,0,0,128).
    const rgba = [_]u8{ 128, 0, 0, 128 };
    var img = try compositeOverCheckerboard(testing.allocator, 1, 1, &rgba);
    defer img.deinit(testing.allocator);
    // Expected: un-premultiply back to ~straight red, then blend 50% over checkerboard
    // shade 0x50 (80): (255*128 + 80*127 + 127)/255 ≈ 168 for R, ~40 for G/B.
    const expected_r = over(255, 0x50, 128);
    try testing.expectEqual(expected_r, img.rgba[0]);
    try testing.expectEqual(@as(u8, 255), img.rgba[3]);
}
