//! Text rendering (issue #131; ADR 0036): a glyph atlas + text layout (advance widths,
//! line breaking) that draws through the `gpu` port by REUSING the existing sprite path —
//! the same `sprite.Atlas`, `gpu.SpriteQuad` batcher, and null-backend CPU rasterizer that
//! sprites use (ADR 0031 §4). There is no parallel text renderer: a glyph is just a
//! textured quad sampling a sub-rect of a font atlas, so `gpu.captureFrame`/`renderFrame`
//! composite text exactly as they composite sprites, and a layout bug reproduces headlessly.
//!
//! The font is an embedded 5x7 bitmap (`font5x7.zig`) — dependency-free, no font-file loader
//! (ADR 0036). Text is COSMETIC and excluded from the state hash: this module reads no sim
//! state and writes no `World` column (it takes a plain `[]const u8`), so — like `Appearance`
//! and `Sprite` (ADR 0030/0031) — it can never perturb `World.stateHash`. Everything here is
//! pure and GPU-free, exercised by the default null-backend gate, so glyph placement, advance
//! widths, and line-break results are all asserted without a window.

const std = @import("std");
const gpu = @import("gpu");
const font = @import("font5x7.zig");
const sprite = @import("sprite.zig");

const Allocator = std.mem.Allocator;

/// The atlas key the font's glyph frames are packed under. A static string literal so a
/// built `sprite.Atlas`'s region `ref`s stay valid after the temporary build storage is
/// freed (see `buildFontAtlas`).
pub const font_ref = "font";

/// Fixed-width layout metrics in font texels (px at scale 1). `tracking` is the gap
/// between adjacent glyph cells; `leading` the gap between lines. Defaults match the
/// embedded 5x7 font: a 6px advance and an 8px line height.
pub const Metrics = struct {
    /// Glyph cell width in texels.
    cell_w: f32 = @floatFromInt(font.width),
    /// Glyph cell height in texels.
    cell_h: f32 = @floatFromInt(font.height),
    /// Horizontal gap between adjacent glyph cells, in texels.
    tracking: f32 = 1,
    /// Vertical gap between successive lines, in texels.
    leading: f32 = 1,

    /// Pen advance for one glyph cell: `cell_w + tracking`.
    pub fn advance(self: Metrics) f32 {
        return self.cell_w + self.tracking;
    }

    /// Baseline-to-baseline line height: `cell_h + leading`.
    pub fn lineHeight(self: Metrics) f32 {
        return self.cell_h + self.leading;
    }
};

/// One laid-out glyph: its ASCII `code` and the top-left of its cell in block-local
/// texels (`x` grows right, `y` grows down; the block origin is `(0, 0)`). Only visible
/// glyphs are emitted — spaces and newlines advance the pen but produce no `Placed`.
pub const Placed = struct {
    code: u8,
    x: f32,
    y: f32,
};

/// A finished layout: the visible glyph placements plus the block's pen-advance `width`
/// (the widest line's pen extent, including each glyph's trailing tracking) and total
/// `height` (`0` for empty text). Owns `glyphs`; carries the `metrics` it was laid out
/// with so `projectText` sizes each cell consistently.
pub const Layout = struct {
    gpa: Allocator,
    glyphs: []Placed,
    width: f32,
    height: f32,
    metrics: Metrics,

    /// Free the glyph slice. Owns nothing else.
    pub fn deinit(self: *Layout) void {
        self.gpa.free(self.glyphs);
    }
};

/// Layout controls: the `metrics` to advance by and an optional word-wrap width (in
/// texels). `max_width` null ⇒ break only on explicit `'\n'`; set ⇒ greedily wrap whole
/// words to a new line when the pen would exceed it, and hard-break a single word wider
/// than the whole line at cell granularity.
pub const Options = struct {
    metrics: Metrics = .{},
    max_width: ?f32 = null,
};

/// A mutable line cursor for `layout`: the pen position (`x`, `y` in texels) plus the
/// widest line's pen extent seen so far. `newline` records the current line's width and
/// drops the pen to the start of the next line — the reset shared by explicit `'\n'` and
/// every wrap point.
const Cursor = struct {
    x: f32 = 0,
    y: f32 = 0,
    max_w: f32 = 0,
    line_height: f32,

    fn newline(self: *Cursor) void {
        self.max_w = @max(self.max_w, self.x);
        self.x = 0;
        self.y += self.line_height;
    }

    /// The final block width, accounting for the last (unterminated) line.
    fn width(self: Cursor) f32 {
        return @max(self.max_w, self.x);
    }
};

/// Lay `text` (ASCII bytes) out into a `Layout` of visible-glyph placements (issue #131):
/// fixed-width advance per cell, `'\n'` forcing a new line, and — when `opts.max_width` is
/// set — greedy word wrapping (a whole word moves to the next line rather than splitting,
/// unless the word alone is wider than the line, in which case it hard-breaks at a cell
/// boundary). Spaces and newlines advance the pen but emit no glyph; a byte outside the
/// font's printable range still consumes a cell but draws nothing (`font.has` is false).
/// Pure and deterministic (integer-cell arithmetic, no I/O, no RNG). Caller owns the
/// returned layout (`deinit`). Errors: `error.OutOfMemory`.
pub fn layout(gpa: Allocator, text: []const u8, opts: Options) Allocator.Error!Layout {
    const m = opts.metrics;
    const adv = m.advance();

    var glyphs: std.ArrayList(Placed) = .empty;
    errdefer glyphs.deinit(gpa);
    var cur: Cursor = .{ .line_height = m.lineHeight() };

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            cur.newline();
            i += 1;
            continue;
        }
        if (c == ' ') {
            cur.x += adv;
            i += 1;
            continue;
        }
        // A word: the maximal run of non-space, non-newline bytes.
        const word_start = i;
        var j = i;
        while (j < text.len and text[j] != ' ' and text[j] != '\n') : (j += 1) {}
        const word_w: f32 = @as(f32, @floatFromInt(j - word_start)) * adv;

        if (opts.max_width) |mw| {
            // Move the whole word to the next line if it does not fit here (but never
            // wrap when already at the line start — that cannot help).
            if (cur.x > 0 and cur.x + word_w > mw) cur.newline();
            // A word wider than the whole line fits on no line — hard-break it at cell
            // granularity so it does not overflow unboundedly, then move on.
            if (word_w > mw) {
                for (text[word_start..j]) |code| {
                    if (cur.x > 0 and cur.x + adv > mw) cur.newline();
                    try placeGlyph(gpa, &glyphs, code, cur.x, cur.y);
                    cur.x += adv;
                }
                i = j;
                continue;
            }
        }

        // Place the whole word on the current line.
        for (text[word_start..j]) |code| {
            try placeGlyph(gpa, &glyphs, code, cur.x, cur.y);
            cur.x += adv;
        }
        i = j;
    }

    return .{
        .gpa = gpa,
        .glyphs = try glyphs.toOwnedSlice(gpa),
        .width = cur.width(),
        .height = if (text.len == 0) 0 else cur.y + m.cell_h,
        .metrics = m,
    };
}

/// Append a `Placed` for `code` at cell top-left (`x`, `y`) — but only if the font has a
/// visible glyph for it (an unrenderable byte consumes its cell without drawing). Shared
/// by `layout`'s hard-break and whole-word paths. Errors: `error.OutOfMemory`.
fn placeGlyph(gpa: Allocator, glyphs: *std.ArrayList(Placed), code: u8, x: f32, y: f32) Allocator.Error!void {
    if (font.has(code)) try glyphs.append(gpa, .{ .code = code, .x = x, .y = y });
}

/// Build the font glyph atlas by REUSING `sprite.buildAtlas` (issue #131; ADR 0031 §4):
/// each printable-ASCII glyph is rasterized to an RGBA8 frame (opaque white ink texel,
/// transparent elsewhere) and packed into one `sprite.Atlas` — the exact atlas type the
/// sprite pipeline samples — so text draws through the same batcher as sprites. A glyph's
/// UV sub-rect is `atlas.uv(font_ref, code - font.first_char)`. The temporary per-glyph
/// frames live in a scratch arena freed before returning; the returned atlas owns its
/// copied pixels and region table, and its region `ref`s point at the static `font_ref`.
/// Caller owns the atlas (`deinit`). Errors: `error.OutOfMemory`.
pub fn buildFontAtlas(gpa: Allocator) Allocator.Error!sprite.Atlas {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const frame_bytes: usize = @as(usize, font.width) * font.height * 4;
    const frames = try arena.alloc([]const u8, font.count);
    for (frames, 0..) |*f, ci| {
        const buf = try arena.alloc(u8, frame_bytes);
        rasterGlyph(font.glyph(@intCast(font.first_char + ci)), buf);
        f.* = buf;
    }

    // A single synthetic sheet keyed `font_ref`; `buildAtlas` copies the pixels out, so
    // freeing the arena afterwards leaves the atlas self-contained.
    var store: sprite.SheetStore = .{ .gpa = gpa };
    defer store.entries.deinit(gpa);
    try store.entries.append(gpa, .{
        .ref = font_ref,
        .sheet = .{ .width = font.width, .height = font.height, .frames = frames, .clips = &.{} },
    });
    return sprite.buildAtlas(gpa, &store);
}

/// Rasterize one 7-row glyph bitmap `g` into `out` (RGBA8, `font.width`×`font.height`,
/// row-major top-to-bottom, matching the MSF frame layout `buildAtlas` expects). A set bit
/// becomes an opaque white texel, a clear bit fully-transparent black; the tint applied at
/// draw time (`projectText`) colours the white ink. Bit `0b10000` of a row is the leftmost
/// column. `out.len` must be `font.width*font.height*4`.
fn rasterGlyph(g: [7]u8, out: []u8) void {
    var row: usize = 0;
    while (row < font.height) : (row += 1) {
        var col: usize = 0;
        while (col < font.width) : (col += 1) {
            const shift: u3 = @intCast(font.width - 1 - col);
            const on = (g[row] >> shift) & 1 != 0;
            const o = (row * font.width + col) * 4;
            const v: u8 = if (on) 255 else 0;
            out[o + 0] = v;
            out[o + 1] = v;
            out[o + 2] = v;
            out[o + 3] = v;
        }
    }
}

/// Where and how a laid-out text block is placed on screen for `projectText`. `origin` is
/// the block's top-left in screen pixels; `scale` is screen px per font texel (an integer
/// keeps the bitmap crisp); `tint` multiplies the white glyph ink (so text can be any
/// colour). `view_w`/`view_h` are the target's pixel size, used to convert to NDC.
pub const Screen = struct {
    view_w: u32,
    view_h: u32,
    origin: [2]f32,
    scale: f32 = 1,
    tint: [3]f32 = .{ 1, 1, 1 },
};

/// Turn a `Layout` into `gpu.SpriteQuad`s that draw its glyphs by sampling `atlas` (issue
/// #131) — the same quad type `render.projectSprites` emits, so the existing null/Vulkan
/// batcher composites text with no new pipeline. Each visible glyph becomes one axis-aligned
/// quad at its cell's projected screen footprint (block `origin` + placement × `scale`),
/// converted to NDC exactly as `render` does (`screen_px/half - 1`), sampling its atlas
/// sub-rect and tinted by `screen.tint`. A glyph whose frame is somehow absent from the
/// atlas is skipped (never fatal). Pure and deterministic; reads no sim state. Caller owns
/// the returned slice. Errors: `error.OutOfMemory`.
pub fn projectText(gpa: Allocator, lay: Layout, atlas: *const sprite.Atlas, screen: Screen) Allocator.Error![]gpu.SpriteQuad {
    const half_w = @as(f32, @floatFromInt(screen.view_w)) / 2;
    const half_h = @as(f32, @floatFromInt(screen.view_h)) / 2;
    const cw = lay.metrics.cell_w * screen.scale;
    const ch = lay.metrics.cell_h * screen.scale;

    var quads: std.ArrayList(gpu.SpriteQuad) = .empty;
    errdefer quads.deinit(gpa);
    for (lay.glyphs) |g| {
        const frame: u16 = @intCast(g.code - font.first_char);
        const region = atlas.uv(font_ref, frame) orelse continue;
        // Cell top-left in screen px, then its centre.
        const sx = screen.origin[0] + g.x * screen.scale;
        const sy = screen.origin[1] + g.y * screen.scale;
        const cx = sx + cw / 2;
        const cy = sy + ch / 2;
        try quads.append(gpa, .{
            .center = .{ cx / half_w - 1, cy / half_h - 1 },
            .half = .{ (cw / 2) / half_w, (ch / 2) / half_h },
            .uv_min = region.min,
            .uv_max = region.max,
            .tint = screen.tint,
        });
    }
    return quads.toOwnedSlice(gpa);
}

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "text layout: fixed-width advances place each glyph one cell to the right" {
    const gpa = testing.allocator;
    var lay = try layout(gpa, "AB", .{});
    defer lay.deinit();

    const adv = (Metrics{}).advance(); // 6
    try testing.expectEqual(@as(usize, 2), lay.glyphs.len);
    try testing.expectEqual(@as(u8, 'A'), lay.glyphs[0].code);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.glyphs[0].x, 1e-6);
    try testing.expectApproxEqAbs(adv, lay.glyphs[1].x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.glyphs[1].y, 1e-6);
    // Pen-advance width is one advance per cell; height is one line.
    try testing.expectApproxEqAbs(2 * adv, lay.width, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, font.height), lay.height, 1e-6);
}

test "text layout: a space advances the pen but emits no glyph" {
    const gpa = testing.allocator;
    var lay = try layout(gpa, "A B", .{});
    defer lay.deinit();

    const adv = (Metrics{}).advance();
    // Two visible glyphs (space is not emitted), but 'B' sits at the third cell.
    try testing.expectEqual(@as(usize, 2), lay.glyphs.len);
    try testing.expectEqual(@as(u8, 'B'), lay.glyphs[1].code);
    try testing.expectApproxEqAbs(2 * adv, lay.glyphs[1].x, 1e-6);
}

test "text layout: a newline starts a new line at x=0" {
    const gpa = testing.allocator;
    var lay = try layout(gpa, "A\nB", .{});
    defer lay.deinit();

    const lh = (Metrics{}).lineHeight(); // 8
    try testing.expectEqual(@as(usize, 2), lay.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.glyphs[1].x, 1e-6);
    try testing.expectApproxEqAbs(lh, lay.glyphs[1].y, 1e-6);
    // Two lines tall: one line-height plus the last line's cell.
    try testing.expectApproxEqAbs(lh + font.height, lay.height, 1e-6);
}

test "text layout: greedy word wrap moves a whole word to the next line" {
    const gpa = testing.allocator;
    // adv=6: "AA" is 12px, a space is 6px more (18), then "BB" (12) → 30 > 20, so "BB" wraps.
    var lay = try layout(gpa, "AA BB", .{ .max_width = 20 });
    defer lay.deinit();

    const lh = (Metrics{}).lineHeight();
    try testing.expectEqual(@as(usize, 4), lay.glyphs.len);
    // "BB" is on the second line, back at x=0.
    try testing.expectEqual(@as(u8, 'B'), lay.glyphs[2].code);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.glyphs[2].x, 1e-6);
    try testing.expectApproxEqAbs(lh, lay.glyphs[2].y, 1e-6);
}

test "text layout: a word wider than the line hard-breaks at a cell boundary" {
    const gpa = testing.allocator;
    // adv=6, max_width=14: fits 2 cells per line (12 ok, 18 overflows), so "AAAA" splits 2+2.
    var lay = try layout(gpa, "AAAA", .{ .max_width = 14 });
    defer lay.deinit();

    const lh = (Metrics{}).lineHeight();
    try testing.expectEqual(@as(usize, 4), lay.glyphs.len);
    // Third glyph wraps to the second line.
    try testing.expectApproxEqAbs(@as(f32, 0), lay.glyphs[2].x, 1e-6);
    try testing.expectApproxEqAbs(lh, lay.glyphs[2].y, 1e-6);
}

test "text layout: empty text yields no glyphs and zero size" {
    const gpa = testing.allocator;
    var lay = try layout(gpa, "", .{});
    defer lay.deinit();
    try testing.expectEqual(@as(usize, 0), lay.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.width, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), lay.height, 1e-6);
}

test "text atlas: every printable glyph has a region; space is blank, a letter is inked" {
    const gpa = testing.allocator;
    var atlas = try buildFontAtlas(gpa);
    defer atlas.deinit();

    // A region exists for the first and last codepoints and for a mid letter.
    try testing.expect(atlas.uv(font_ref, 0) != null); // space
    try testing.expect(atlas.uv(font_ref, font.count - 1) != null); // tilde
    try testing.expect(atlas.uv(font_ref, 'A' - font.first_char) != null);

    // Sum the alpha under a glyph's atlas sub-rect: space has no ink, 'A' does.
    try testing.expectEqual(@as(u32, 0), inkUnder(&atlas, ' '));
    try testing.expect(inkUnder(&atlas, 'A') > 0);
}

/// Total alpha (0..255 summed) of the atlas texels under codepoint `c`'s sub-rect — a
/// measure of how much ink a glyph carries, used to assert blank vs. inked glyphs.
fn inkUnder(atlas: *const sprite.Atlas, c: u8) u32 {
    const region = atlas.uv(font_ref, @as(u16, @intCast(c - font.first_char))).?;
    const x0: u32 = @intFromFloat(@round(region.min[0] * @as(f32, @floatFromInt(atlas.width))));
    const y0: u32 = @intFromFloat(@round(region.min[1] * @as(f32, @floatFromInt(atlas.height))));
    var sum: u32 = 0;
    var y: u32 = 0;
    while (y < font.height) : (y += 1) {
        var x: u32 = 0;
        while (x < font.width) : (x += 1) {
            const o = (@as(usize, y0 + y) * atlas.width + (x0 + x)) * 4;
            sum += atlas.pixels[o + 3];
        }
    }
    return sum;
}

test "text render: a glyph composites ink through the null backend; a space draws nothing" {
    // End-to-end headless proof (issue #131): layout → projectText → the SAME
    // `gpu.captureFrame` sprites use → the null backend samples the font atlas and
    // alpha-blends the glyph over the clear. A glyph must leave ink inside its cell and
    // the background must survive outside it; a space must leave the frame untouched.
    const gpa = testing.allocator;
    var atlas = try buildFontAtlas(gpa);
    defer atlas.deinit();

    const view_w: u32 = 64;
    const view_h: u32 = 32;
    // Draw a big 'A' near the top-left; scale 3 → a 15x21px glyph.
    const screen: Screen = .{ .view_w = view_w, .view_h = view_h, .origin = .{ 4, 4 }, .scale = 3, .tint = .{ 1, 1, 1 } };

    var lay = try layout(gpa, "A", .{});
    defer lay.deinit();
    const quads = try projectText(gpa, lay, &atlas, screen);
    defer gpa.free(quads);
    try testing.expectEqual(@as(usize, 1), quads.len);

    const pixels = gpu.captureFrame(gpa, view_w, view_h, &.{}, quads, atlas.pixels, atlas.width, atlas.height, .{ 0, 0, 0, 1 }) catch |e| {
        if (gpu.backend != .null_backend) return error.SkipZigTest; // no GPU device in this env
        return e;
    };
    defer gpa.free(pixels);

    // Some ink landed inside the glyph's on-screen footprint (rows 4..25, cols 4..19).
    var lit: u32 = 0;
    var y: u32 = 4;
    while (y < 25) : (y += 1) {
        var x: u32 = 4;
        while (x < 19) : (x += 1) {
            if (pixels[(@as(usize, y) * view_w + x) * 4 + 0] > 0) lit += 1;
        }
    }
    try testing.expect(lit > 0);
    // A far corner outside the glyph stays the black clear (no stray ink).
    const corner = (@as(usize, view_h - 1) * view_w + (view_w - 1)) * 4;
    try testing.expectEqual(@as(u8, 0), pixels[corner + 0]);

    // A space produces no quads at all — nothing to composite.
    var blank = try layout(gpa, " ", .{});
    defer blank.deinit();
    const none = try projectText(gpa, blank, &atlas, screen);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "text render: tint colours the glyph ink" {
    // The white glyph ink multiplied by a red tint composites red — proving the same
    // tint path sprites use applies to text (a HUD can colour its labels).
    const gpa = testing.allocator;
    var atlas = try buildFontAtlas(gpa);
    defer atlas.deinit();

    const view_w: u32 = 48;
    const view_h: u32 = 24;
    const screen: Screen = .{ .view_w = view_w, .view_h = view_h, .origin = .{ 2, 2 }, .scale = 3, .tint = .{ 1, 0, 0 } };
    var lay = try layout(gpa, "H", .{}); // 'H' has ink in its corners
    defer lay.deinit();
    const quads = try projectText(gpa, lay, &atlas, screen);
    defer gpa.free(quads);

    const pixels = gpu.captureFrame(gpa, view_w, view_h, &.{}, quads, atlas.pixels, atlas.width, atlas.height, .{ 0, 0, 0, 1 }) catch |e| {
        if (gpu.backend != .null_backend) return error.SkipZigTest;
        return e;
    };
    defer gpa.free(pixels);

    // Scan the glyph footprint: any lit pixel is red (R set, B zero — the tint has no blue).
    var found_red = false;
    var y: u32 = 2;
    while (y < 23) : (y += 1) {
        var x: u32 = 2;
        while (x < 17) : (x += 1) {
            const o = (@as(usize, y) * view_w + x) * 4;
            if (pixels[o + 0] > 0) {
                found_red = true;
                try testing.expectEqual(@as(u8, 0), pixels[o + 2]); // no blue in a red tint
            }
        }
    }
    try testing.expect(found_red);
}
