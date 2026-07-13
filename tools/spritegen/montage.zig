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

    // Fill the whole image with the checkerboard first.
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
