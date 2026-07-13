//! A tiny, deterministic software rasterizer for `spritegen` (ADR 0031). It knows
//! only genre-neutral primitives — disc, wedge, dome, eye-pair, rect, rounded-rect,
//! line — drawn onto a premultiplied-alpha float `Canvas` with fixed-order 4×4
//! supersampling. It has no RNG, no time source, and no floating-point behaviour
//! beyond IEEE arithmetic, so the same calls in the same order always produce the
//! same pixels (`spritegen` relies on this; a determinism test pins it).
//!
//! Coordinates are **normalized 0..1** over a square canvas: `(0,0)` is the top-left
//! pixel corner, `(1,1)` the bottom-right. Positions map by canvas width/height;
//! radii/lengths use the width as their unit, so a recipe is resolution-independent
//! (author a 32² sheet or a 256² sheet from the same numbers). Y grows downward, as
//! in the output image.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An RGBA colour in straight (non-premultiplied) form, each channel 0..1. A colour
/// with `a == 0` is the **erase** colour: painting it clears coverage to transparent
/// (used to cut a mouth out of a disc), rather than compositing nothing.
pub const Rgba = [4]f32;

/// A mutable drawing surface holding **premultiplied** RGBA in `f32` (so anti-aliased
/// edges over transparency composite correctly). Convert to straight-alpha RGBA8 with
/// `toRgba8` when done. Square canvases only (radii use width as their unit).
pub const Canvas = struct {
    width: u32,
    height: u32,
    /// `width*height*4` premultiplied RGBA floats, row-major, top-to-bottom.
    pix: []f32,

    /// Allocate a `width`×`height` canvas filled with `background` (straight alpha;
    /// pass `.{0,0,0,0}` for transparent). Caller owns it; free with `deinit`.
    pub fn init(gpa: Allocator, width: u32, height: u32, background: Rgba) Allocator.Error!Canvas {
        const pix = try gpa.alloc(f32, @as(usize, width) * height * 4);
        const ba = background[3];
        var i: usize = 0;
        while (i < pix.len) : (i += 4) {
            pix[i + 0] = background[0] * ba;
            pix[i + 1] = background[1] * ba;
            pix[i + 2] = background[2] * ba;
            pix[i + 3] = ba;
        }
        return .{ .width = width, .height = height, .pix = pix };
    }

    /// Free the pixel storage.
    pub fn deinit(self: *Canvas, gpa: Allocator) void {
        gpa.free(self.pix);
        self.* = undefined;
    }

    /// Composite `color` onto pixel `(x,y)` with `coverage` in 0..1. An erase colour
    /// (`color[3] == 0`) scales the destination down by `1 - coverage`; any other
    /// colour is source-over composited with source alpha `color[3] * coverage`.
    fn paint(self: *Canvas, x: u32, y: u32, color: Rgba, coverage: f32) void {
        if (coverage <= 0) return;
        const idx = (@as(usize, y) * self.width + x) * 4;
        const d = self.pix[idx..][0..4];
        if (color[3] == 0) {
            const keep = 1 - coverage;
            for (d) |*c| c.* *= keep;
            return;
        }
        const sa = color[3] * coverage; // source alpha
        const inv = 1 - sa;
        d[0] = color[0] * sa + d[0] * inv;
        d[1] = color[1] * sa + d[1] * inv;
        d[2] = color[2] * sa + d[2] * inv;
        d[3] = sa + d[3] * inv;
    }

    /// Convert to straight-alpha RGBA8, row-major top-to-bottom (`width*height*4`
    /// bytes). Caller owns the result. Un-premultiplies each pixel; a fully
    /// transparent pixel yields all-zero bytes.
    pub fn toRgba8(self: *const Canvas, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, self.pix.len);
        var i: usize = 0;
        while (i < self.pix.len) : (i += 4) {
            const a = self.pix[i + 3];
            if (a <= 0) {
                @memset(out[i..][0..4], 0);
                continue;
            }
            out[i + 0] = unit8(self.pix[i + 0] / a);
            out[i + 1] = unit8(self.pix[i + 1] / a);
            out[i + 2] = unit8(self.pix[i + 2] / a);
            out[i + 3] = unit8(a);
        }
        return out;
    }
};

/// Quantize a 0..1 float to a 0..255 byte with round-to-nearest, clamped. Deterministic.
fn unit8(v: f32) u8 {
    const c = std.math.clamp(v, 0, 1);
    return @intFromFloat(@round(c * 255));
}

/// Supersampling grid edge (samples per pixel = `ss*ss`). Fixed so output is stable.
const ss = 4;

/// Fill every pixel whose supersampled centre satisfies `ctx.inside(nx, ny)` with
/// `color`, computing per-pixel coverage from the fraction of the `ss*ss` samples
/// inside. `ctx` is any value with `fn inside(self, nx: f32, ny: f32) bool`.
fn fill(canvas: *Canvas, color: Rgba, ctx: anytype) void {
    const fw: f32 = @floatFromInt(canvas.width);
    const fh: f32 = @floatFromInt(canvas.height);
    var y: u32 = 0;
    while (y < canvas.height) : (y += 1) {
        var x: u32 = 0;
        while (x < canvas.width) : (x += 1) {
            var hits: u32 = 0;
            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const fx: f32 = @floatFromInt(x);
                    const fy: f32 = @floatFromInt(y);
                    const nx = (fx + (@as(f32, @floatFromInt(sx)) + 0.5) / ss) / fw;
                    const ny = (fy + (@as(f32, @floatFromInt(sy)) + 0.5) / ss) / fh;
                    if (ctx.inside(nx, ny)) hits += 1;
                }
            }
            if (hits == 0) continue;
            const cov = @as(f32, @floatFromInt(hits)) / (ss * ss);
            canvas.paint(x, y, color, cov);
        }
    }
}

// --- Primitives (all params normalized 0..1) --------------------------------------

/// Fill a disc of radius `r` centred at `(cx,cy)` with `color`.
pub fn disc(canvas: *Canvas, cx: f32, cy: f32, r: f32, color: Rgba) void {
    fill(canvas, color, DiscCtx{ .cx = cx, .cy = cy, .r2 = r * r });
}

const DiscCtx = struct {
    cx: f32,
    cy: f32,
    r2: f32,
    fn inside(self: DiscCtx, nx: f32, ny: f32) bool {
        const dx = nx - self.cx;
        const dy = ny - self.cy;
        return dx * dx + dy * dy <= self.r2;
    }
};

/// Fill the pie sector of a disc: radius `r` at `(cx,cy)`, between angles `a0`..`a1`
/// (degrees, measured from +x, increasing clockwise in image space — y is down). The
/// sector is the swept range from `a0` to `a1` going clockwise; e.g. `a0=-30, a1=30`
/// is a 60° wedge opening to the right (a Pac-Man mouth). Fill with the erase colour
/// to cut a mouth out of an already-drawn disc.
pub fn wedge(canvas: *Canvas, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, color: Rgba) void {
    fill(canvas, color, WedgeCtx{
        .cx = cx,
        .cy = cy,
        .r2 = r * r,
        .a0 = norm360(a0),
        .span = norm360(a1 - a0),
    });
}

const WedgeCtx = struct {
    cx: f32,
    cy: f32,
    r2: f32,
    a0: f32,
    span: f32,
    fn inside(self: WedgeCtx, nx: f32, ny: f32) bool {
        const dx = nx - self.cx;
        const dy = ny - self.cy;
        if (dx * dx + dy * dy > self.r2) return false;
        const ang = norm360(std.math.radiansToDegrees(std.math.atan2(dy, dx)));
        const rel = norm360(ang - self.a0);
        return rel <= self.span;
    }
};

/// Wrap an angle in degrees to [0, 360).
fn norm360(deg: f32) f32 {
    const m = @mod(deg, 360);
    return if (m < 0) m + 360 else m;
}

/// Fill a "dome + skirt" body — a ghost silhouette: a semicircular top of radius `r`
/// centred at `(cx,cy)`, a rectangular body down to `cy + height`, and a scalloped
/// bottom edge of `bumps` rounded tabs (each tab drops by `skirt`). Genre-neutral: it
/// is just a capped rectangle with a wavy bottom.
pub fn dome(canvas: *Canvas, cx: f32, cy: f32, r: f32, height: f32, bumps: u32, skirt: f32, color: Rgba) void {
    fill(canvas, color, DomeCtx{
        .cx = cx,
        .cy = cy,
        .r = r,
        .bottom = cy + height,
        .bumps = @floatFromInt(@max(bumps, 1)),
        .skirt = skirt,
    });
}

const DomeCtx = struct {
    cx: f32,
    cy: f32,
    r: f32,
    bottom: f32,
    bumps: f32,
    skirt: f32,
    fn inside(self: DomeCtx, nx: f32, ny: f32) bool {
        const dx = nx - self.cx;
        if (@abs(dx) > self.r) return false;
        if (ny <= self.cy) {
            const dy = ny - self.cy;
            return dx * dx + dy * dy <= self.r * self.r; // rounded dome top
        }
        // Scalloped bottom: a triangle wave across each bump, deepest (lowest) at the
        // bump centre, receding by `skirt` at the notches between tabs.
        const bump_w = (2 * self.r) / self.bumps;
        const pos = (nx - (self.cx - self.r)) / bump_w; // bumps along the width
        const local = pos - @floor(pos); // 0..1 within a bump
        const tri = @abs(2 * local - 1); // 0 at centre, 1 at edges
        const edge = self.bottom - self.skirt * tri;
        return ny <= edge;
    }
};

/// Draw a pair of eyes centred about `(cx,cy)`, `spacing` apart, each a white disc of
/// radius `r` with a pupil disc of radius `pupil_r` offset by `(look_x, look_y)`
/// (normalized, relative to the eye centre — a gaze direction). Composed of four disc
/// fills, so it obeys the same painter's-order semantics as any other primitive.
pub fn eyes(
    canvas: *Canvas,
    cx: f32,
    cy: f32,
    spacing: f32,
    r: f32,
    pupil_r: f32,
    look_x: f32,
    look_y: f32,
    white: Rgba,
    pupil: Rgba,
) void {
    const lx = cx - spacing / 2;
    const rx = cx + spacing / 2;
    disc(canvas, lx, cy, r, white);
    disc(canvas, rx, cy, r, white);
    disc(canvas, lx + look_x, cy + look_y, pupil_r, pupil);
    disc(canvas, rx + look_x, cy + look_y, pupil_r, pupil);
}

/// Fill an axis-aligned rectangle with top-left `(x,y)` and size `(w,h)`.
pub fn rect(canvas: *Canvas, x: f32, y: f32, w: f32, h: f32, color: Rgba) void {
    fill(canvas, color, RectCtx{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h });
}

const RectCtx = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    fn inside(self: RectCtx, nx: f32, ny: f32) bool {
        return nx >= self.x0 and nx < self.x1 and ny >= self.y0 and ny < self.y1;
    }
};

/// Fill a rounded rectangle: top-left `(x,y)`, size `(w,h)`, corner radius `radius`.
pub fn roundedRect(canvas: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Rgba) void {
    const rad = @min(radius, @min(w, h) / 2);
    fill(canvas, color, RoundRectCtx{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h, .r = rad });
}

const RoundRectCtx = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    r: f32,
    fn inside(self: RoundRectCtx, nx: f32, ny: f32) bool {
        if (nx < self.x0 or nx >= self.x1 or ny < self.y0 or ny >= self.y1) return false;
        // Clamp the point to the inner rect (corners' centres); outside the radius of
        // the nearest corner centre ⇒ cut off.
        const ix = std.math.clamp(nx, self.x0 + self.r, self.x1 - self.r);
        const iy = std.math.clamp(ny, self.y0 + self.r, self.y1 - self.r);
        const dx = nx - ix;
        const dy = ny - iy;
        return dx * dx + dy * dy <= self.r * self.r;
    }
};

/// Draw a line segment from `(x0,y0)` to `(x1,y1)` of the given `thickness` (its full
/// width; the stroke is a capsule around the segment centreline).
pub fn line(canvas: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: Rgba) void {
    fill(canvas, color, LineCtx{ .x0 = x0, .y0 = y0, .dx = x1 - x0, .dy = y1 - y0, .half2 = (thickness / 2) * (thickness / 2) });
}

const LineCtx = struct {
    x0: f32,
    y0: f32,
    dx: f32,
    dy: f32,
    half2: f32,
    fn inside(self: LineCtx, nx: f32, ny: f32) bool {
        const len2 = self.dx * self.dx + self.dy * self.dy;
        const t = if (len2 == 0) 0 else std.math.clamp(((nx - self.x0) * self.dx + (ny - self.y0) * self.dy) / len2, 0, 1);
        const px = self.x0 + t * self.dx;
        const py = self.y0 + t * self.dy;
        const ex = nx - px;
        const ey = ny - py;
        return ex * ex + ey * ey <= self.half2;
    }
};

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "raster: a full-canvas opaque rect fills every pixel opaque" {
    var c = try Canvas.init(testing.allocator, 8, 8, .{ 0, 0, 0, 0 });
    defer c.deinit(testing.allocator);
    rect(&c, 0, 0, 1, 1, .{ 1, 0, 0, 1 });
    const bytes = try c.toRgba8(testing.allocator);
    defer testing.allocator.free(bytes);
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 255), bytes[i + 0]); // red
        try testing.expectEqual(@as(u8, 255), bytes[i + 3]); // opaque
    }
}

test "raster: erase colour cuts a transparent hole" {
    var c = try Canvas.init(testing.allocator, 16, 16, .{ 0, 0, 0, 0 });
    defer c.deinit(testing.allocator);
    disc(&c, 0.5, 0.5, 0.5, .{ 1, 1, 0, 1 }); // yellow disc
    rect(&c, 0, 0, 1, 1, .{ 0, 0, 0, 0 }); // erase everything
    const bytes = try c.toRgba8(testing.allocator);
    defer testing.allocator.free(bytes);
    for (bytes) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "raster: disc centre is opaque, far corner is transparent" {
    var c = try Canvas.init(testing.allocator, 16, 16, .{ 0, 0, 0, 0 });
    defer c.deinit(testing.allocator);
    disc(&c, 0.5, 0.5, 0.3, .{ 0, 1, 0, 1 });
    const bytes = try c.toRgba8(testing.allocator);
    defer testing.allocator.free(bytes);
    const centre = (8 * c.width + 8) * 4;
    try testing.expectEqual(@as(u8, 255), bytes[centre + 3]);
    try testing.expectEqual(@as(u8, 0), bytes[0 + 3]); // top-left corner
}

test "raster: byte-identical across two runs (determinism)" {
    const draw = struct {
        fn go(gpa: Allocator) ![]u8 {
            var c = try Canvas.init(gpa, 24, 24, .{ 0.1, 0.1, 0.1, 1 });
            defer c.deinit(gpa);
            disc(&c, 0.5, 0.5, 0.45, .{ 1, 0.9, 0.2, 1 });
            wedge(&c, 0.5, 0.5, 0.5, -25, 25, .{ 0, 0, 0, 0 });
            dome(&c, 0.5, 0.55, 0.4, 0.35, 3, 0.1, .{ 0.3, 0.6, 1, 1 });
            eyes(&c, 0.5, 0.45, 0.3, 0.09, 0.04, 0.02, 0, .{ 1, 1, 1, 1 }, .{ 0, 0, 0, 1 });
            return c.toRgba8(gpa);
        }
    }.go;
    const a = try draw(testing.allocator);
    defer testing.allocator.free(a);
    const b = try draw(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}
