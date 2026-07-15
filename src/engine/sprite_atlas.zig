//! CPU sprite-atlas assembly, split out of `sprite.zig` (issue #151; the parent file
//! crossed the ~500-line soft limit). Cohesive on its own: packing a `SheetStore`'s
//! decoded frames into one GPU-uploadable image (issue #113 phase 2b; ADR 0031 §4) is a
//! distinct concern from `sprite.zig`'s (a) loading sheets off disk and (b) advancing an
//! entity's animation cursor. Depends on `sprite.zig` only for the `SheetStore` it packs.
//! Re-exported as `sprite.Atlas`/`sprite.Region`/`sprite.buildAtlas`/`sprite.merge` so the
//! public API is unchanged.

const std = @import("std");
const sprite = @import("sprite.zig");

const Allocator = std.mem.Allocator;
const SheetStore = sprite.SheetStore;

/// The atlas sub-rect one sheet frame occupies (issue #113 phase 2b; ADR 0031 §4).
/// `ref` is the owning sheet's `Sprite.sheet` key (borrowed from the `SheetStore`, which
/// borrows it from the world); `frame` is the index into that sheet's `frames`; `uv_*`
/// are the frame's top-left/bottom-right corners in atlas UV space (0..1).
pub const Region = struct {
    ref: []const u8,
    frame: u16,
    uv_min: [2]f32,
    uv_max: [2]f32,
};

/// A CPU-assembled sprite atlas (ADR 0031 §4): every frame of every loaded sheet packed
/// into ONE RGBA8 image, plus a lookup from (sheet ref, frame index) → UV sub-rect.
/// Built once per world load from a `SheetStore` and uploaded to a single GPU texture the
/// sprite pipeline samples, so a whole scene's sprites draw from one bound texture. Owns
/// its `pixels` and `regions` (freed by `deinit`); `Region.ref` keys are borrowed from
/// the store. An empty store yields a zero-sized atlas (`width == 0`), which the caller
/// skips uploading/drawing.
pub const Atlas = struct {
    gpa: Allocator,
    width: u32,
    height: u32,
    /// Tightly-packed RGBA8, `width*height*4` bytes (empty when `width == 0`), owned.
    pixels: []u8,
    /// One entry per packed frame, owned. `ref` keys are borrowed (see above).
    regions: []Region,

    /// Free the atlas pixels and region table. `ref` keys are borrowed and not freed.
    pub fn deinit(self: *Atlas) void {
        self.gpa.free(self.pixels);
        self.gpa.free(self.regions);
    }

    /// The UV sub-rect for sheet `ref`'s frame index `frame`, or null if not packed.
    /// Borrowed values (plain floats); valid until `deinit`. Linear scan: frame counts
    /// are tiny (one small atlas per scene).
    pub fn uv(self: *const Atlas, ref: []const u8, frame: u16) ?struct { min: [2]f32, max: [2]f32 } {
        for (self.regions) |r| {
            if (r.frame == frame and std.mem.eql(u8, r.ref, ref)) return .{ .min = r.uv_min, .max = r.uv_max };
        }
        return null;
    }
};

/// Assemble every frame of every sheet in `store` into a single `Atlas` (issue #113
/// phase 2b; ADR 0031 §4). Frames are placed in a square-ish, uniform-cell grid (each
/// cell sized to the largest frame across all sheets; a smaller frame sits in its cell's
/// top-left with the remainder left transparent), in store then frame order — a
/// deterministic layout. Frame pixels are RGBA8 row-major top-to-bottom (the MSF layout,
/// ADR 0031 §2), copied row-by-row so the atlas UVs address them the same way. Caller
/// owns the atlas (`deinit`). Errors: `error.OutOfMemory`.
pub fn buildAtlas(gpa: Allocator, store: *const SheetStore) Allocator.Error!Atlas {
    var total: usize = 0;
    var cell_w: u32 = 0;
    var cell_h: u32 = 0;
    for (store.entries.items) |*e| {
        total += e.sheet.frames.len;
        cell_w = @max(cell_w, e.sheet.width);
        cell_h = @max(cell_h, e.sheet.height);
    }
    if (total == 0) return .{ .gpa = gpa, .width = 0, .height = 0, .pixels = try gpa.alloc(u8, 0), .regions = try gpa.alloc(Region, 0) };

    // ceil(sqrt(total)) columns → a roughly square atlas; rows follow.
    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(total)))));
    const rows: u32 = @intCast((total + cols - 1) / cols);
    const aw = cols * cell_w;
    const ah = rows * cell_h;

    const pixels = try gpa.alloc(u8, @as(usize, aw) * ah * 4);
    @memset(pixels, 0);
    errdefer gpa.free(pixels);
    const regions = try gpa.alloc(Region, total);
    errdefer gpa.free(regions);

    const awf: f32 = @floatFromInt(aw);
    const ahf: f32 = @floatFromInt(ah);
    var slot: usize = 0;
    for (store.entries.items) |*e| {
        const fw = e.sheet.width;
        const fh = e.sheet.height;
        for (e.sheet.frames, 0..) |frame_px, fi| {
            const col: u32 = @intCast(slot % cols);
            const row: u32 = @intCast(slot / cols);
            const x0 = col * cell_w;
            const y0 = row * cell_h;
            var y: u32 = 0;
            while (y < fh) : (y += 1) {
                const src = frame_px[@as(usize, y) * fw * 4 ..][0 .. @as(usize, fw) * 4];
                const dst_off = (@as(usize, y0 + y) * aw + x0) * 4;
                @memcpy(pixels[dst_off .. dst_off + @as(usize, fw) * 4], src);
            }
            regions[slot] = .{
                .ref = e.ref,
                .frame = @intCast(fi),
                .uv_min = .{ @as(f32, @floatFromInt(x0)) / awf, @as(f32, @floatFromInt(y0)) / ahf },
                .uv_max = .{ @as(f32, @floatFromInt(x0 + fw)) / awf, @as(f32, @floatFromInt(y0 + fh)) / ahf },
            };
            slot += 1;
        }
    }
    return .{ .gpa = gpa, .width = aw, .height = ah, .pixels = pixels, .regions = regions };
}

/// Stack atlas `b` directly below atlas `a` into ONE new `Atlas` (issue #133): the merged
/// image is `max(a.width, b.width)` wide and `a.height + b.height` tall, with `a`'s pixels
/// at the top-left and `b`'s below them, and a region table carrying BOTH atlases' regions
/// with their UVs recomputed against the merged dimensions. This is how a HUD composites in
/// ONE `gpu.captureFrame`/`renderFrame` call: the scene sprite atlas and the font glyph
/// atlas (`text.buildFontAtlas`) merge, so both game sprites (`ref`s from `a`) and label
/// glyphs (`text.font_ref`, from `b`) sample the single bound texture the sprite pass binds.
/// A region's UVs address the exact same source texels after the merge (nearest-neighbour
/// sampling, `floor(uv*dim)`, is preserved), so a sprite drawn through the merged atlas is
/// pixel-identical to one drawn through `a` alone. Either atlas may be zero-sized (an empty
/// scene, or no font): the other is copied through. `Region.ref` keys are BORROWED from `a`
/// and `b` (never copied), so both source atlases — and whatever backs their `ref`s — must
/// outlive the merged atlas. Caller owns it (`deinit`). Errors: `error.OutOfMemory`.
pub fn merge(gpa: Allocator, a: *const Atlas, b: *const Atlas) Allocator.Error!Atlas {
    const mw = @max(a.width, b.width);
    const mh = a.height + b.height;
    if (mw == 0 or mh == 0) return .{ .gpa = gpa, .width = 0, .height = 0, .pixels = try gpa.alloc(u8, 0), .regions = try gpa.alloc(Region, 0) };

    const pixels = try gpa.alloc(u8, @as(usize, mw) * mh * 4);
    @memset(pixels, 0);
    errdefer gpa.free(pixels);
    const regions = try gpa.alloc(Region, a.regions.len + b.regions.len);
    errdefer gpa.free(regions);

    // Copy each source atlas row-by-row into the merged sheet (widths may differ, so a
    // per-row copy — never a single memcpy — keeps each source left-aligned).
    copyRows(pixels, mw, a.pixels, a.width, a.height, 0);
    copyRows(pixels, mw, b.pixels, b.width, b.height, a.height);

    const mwf: f32 = @floatFromInt(mw);
    const mhf: f32 = @floatFromInt(mh);
    for (a.regions, regions[0..a.regions.len]) |src, *dst| dst.* = remapRegion(src, a.width, a.height, 0, mwf, mhf);
    for (b.regions, regions[a.regions.len..]) |src, *dst| dst.* = remapRegion(src, b.width, b.height, a.height, mwf, mhf);

    return .{ .gpa = gpa, .width = mw, .height = mh, .pixels = pixels, .regions = regions };
}

/// Copy an `sw`×`sh` RGBA8 source into `dst` (a `dw`-wide RGBA8 sheet) left-aligned at
/// vertical offset `y_off`, one row at a time (source and destination strides differ).
fn copyRows(dst: []u8, dw: u32, src: []const u8, sw: u32, sh: u32, y_off: u32) void {
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        const s = @as(usize, y) * sw * 4;
        const d = (@as(usize, y_off + y) * dw) * 4;
        @memcpy(dst[d .. d + @as(usize, sw) * 4], src[s .. s + @as(usize, sw) * 4]);
    }
}

/// Remap one `Region` from a source atlas (`sw`×`sh`, placed at vertical offset `y_off` in
/// the merged sheet) into merged-normalized UVs. The source UVs are recovered to exact pixel
/// columns/rows (`round(uv*dim)` — the atlas builder emits `px/dim`, so the round is
/// lossless), shifted down by `y_off` texels, then re-normalized against the merged
/// `mwf`×`mhf` so a nearest-neighbour sample lands on the same source texel.
fn remapRegion(src: Region, sw: u32, sh: u32, y_off: u32, mwf: f32, mhf: f32) Region {
    const swf: f32 = @floatFromInt(sw);
    const shf: f32 = @floatFromInt(sh);
    const yo: f32 = @floatFromInt(y_off);
    return .{
        .ref = src.ref,
        .frame = src.frame,
        .uv_min = .{ @round(src.uv_min[0] * swf) / mwf, (@round(src.uv_min[1] * shf) + yo) / mhf },
        .uv_max = .{ @round(src.uv_max[0] * swf) / mwf, (@round(src.uv_max[1] * shf) + yo) / mhf },
    };
}

const testing = std.testing;
const msf = @import("data").msf;

/// Build a `SheetStore` owning one decoded sheet under `ref` (encode→decode so the store
/// owns freeable slices, matching `sprite.loadForScene`). Caller `deinit`s the returned
/// store.
fn storeWith(gpa: Allocator, ref: []const u8, sheet: msf.Sheet) !SheetStore {
    const bytes = try msf.encode(gpa, sheet);
    defer gpa.free(bytes);
    const owned = try msf.decode(gpa, bytes);
    var store: SheetStore = .{ .gpa = gpa };
    try store.entries.append(gpa, .{ .ref = ref, .sheet = owned });
    return store;
}

test "sprite: buildAtlas packs frames into a grid with per-frame UVs" {
    const gpa = testing.allocator;
    // Two distinct 2x2 RGBA frames.
    var f0: [2 * 2 * 4]u8 = undefined;
    var f1: [2 * 2 * 4]u8 = undefined;
    for (&f0, 0..) |*b, i| b.* = @intCast(i & 0xff);
    for (&f1, 0..) |*b, i| b.* = @intCast((200 + i) & 0xff);
    var store = try storeWith(gpa, "s.msf", .{
        .width = 2,
        .height = 2,
        .frames = &.{ &f0, &f1 },
        .clips = &.{},
    });
    defer store.deinit();

    var atlas = try buildAtlas(gpa, &store);
    defer atlas.deinit();

    // 2 frames → cols = ceil(sqrt 2) = 2, rows = 1 → a 4x2 atlas of two 2x2 cells.
    try testing.expectEqual(@as(u32, 4), atlas.width);
    try testing.expectEqual(@as(u32, 2), atlas.height);

    // Frame 0 occupies the left cell [0,0.5); frame 1 the right cell [0.5,1].
    const uv0 = atlas.uv("s.msf", 0).?;
    try testing.expectApproxEqAbs(@as(f32, 0), uv0.min[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), uv0.max[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), uv0.max[1], 1e-6);
    const uv1 = atlas.uv("s.msf", 1).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), uv1.min[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), uv1.max[0], 1e-6);

    // Frame 0's first texel lands at atlas (0,0); frame 1's at atlas (2,0) → byte 8.
    try testing.expectEqual(f0[0], atlas.pixels[0]);
    try testing.expectEqual(f1[0], atlas.pixels[2 * 4]);
    // An unknown sheet/frame is absent.
    try testing.expect(atlas.uv("nope.msf", 0) == null);
    try testing.expect(atlas.uv("s.msf", 9) == null);
}

test "sprite: buildAtlas on an empty store yields a zero-sized atlas" {
    const gpa = testing.allocator;
    var store: SheetStore = .{ .gpa = gpa };
    defer store.deinit();
    var atlas = try buildAtlas(gpa, &store);
    defer atlas.deinit();
    try testing.expectEqual(@as(u32, 0), atlas.width);
    try testing.expectEqual(@as(usize, 0), atlas.regions.len);
}

test "sprite: merge stacks two atlases and both refs resolve to their original texels" {
    const gpa = testing.allocator;
    // Atlas A: one 2x2 sheet "a" with a distinct top-left texel.
    var af: [2 * 2 * 4]u8 = undefined;
    for (&af, 0..) |*b, i| b.* = @intCast((10 + i) & 0xff);
    var sa = try storeWith(gpa, "a.msf", .{ .width = 2, .height = 2, .frames = &.{&af}, .clips = &.{} });
    defer sa.deinit();
    var atlas_a = try buildAtlas(gpa, &sa);
    defer atlas_a.deinit();

    // Atlas B: one 2x2 sheet "b" with a different marker texel.
    var bf: [2 * 2 * 4]u8 = undefined;
    for (&bf, 0..) |*b, i| b.* = @intCast((100 + i) & 0xff);
    var sb = try storeWith(gpa, "b.msf", .{ .width = 2, .height = 2, .frames = &.{&bf}, .clips = &.{} });
    defer sb.deinit();
    var atlas_b = try buildAtlas(gpa, &sb);
    defer atlas_b.deinit();

    var m = try merge(gpa, &atlas_a, &atlas_b);
    defer m.deinit();

    // Merged sheet is A over B: 2 wide, 4 tall, both regions present.
    try testing.expectEqual(@as(u32, 2), m.width);
    try testing.expectEqual(@as(u32, 4), m.height);
    try testing.expectEqual(@as(usize, 2), m.regions.len);
    try testing.expect(m.uv("a.msf", 0) != null);
    try testing.expect(m.uv("b.msf", 0) != null);

    // Each ref's UV, sampled nearest-neighbour (floor(uv*dim)), lands on its own texel:
    // A's first texel is at merged (0,0); B's first texel is at merged (0,2) — byte
    // offset (2*2)*4 = 16 — proving B was stacked below A and its UVs shifted down.
    const uva = m.uv("a.msf", 0).?;
    const ax: u32 = @intFromFloat(@floor(uva.min[0] * @as(f32, @floatFromInt(m.width))));
    const ay: u32 = @intFromFloat(@floor(uva.min[1] * @as(f32, @floatFromInt(m.height))));
    try testing.expectEqual(af[0], m.pixels[(@as(usize, ay) * m.width + ax) * 4]);

    const uvb = m.uv("b.msf", 0).?;
    const bx: u32 = @intFromFloat(@floor(uvb.min[0] * @as(f32, @floatFromInt(m.width))));
    const by: u32 = @intFromFloat(@floor(uvb.min[1] * @as(f32, @floatFromInt(m.height))));
    try testing.expectEqual(@as(u32, 2), by); // shifted down by A's height
    try testing.expectEqual(bf[0], m.pixels[(@as(usize, by) * m.width + bx) * 4]);
}

test "sprite: merge with an empty atlas copies the other through unchanged" {
    const gpa = testing.allocator;
    var f: [2 * 2 * 4]u8 = undefined;
    for (&f, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var store = try storeWith(gpa, "s.msf", .{ .width = 2, .height = 2, .frames = &.{&f}, .clips = &.{} });
    defer store.deinit();
    var atlas = try buildAtlas(gpa, &store);
    defer atlas.deinit();

    // An empty font atlas (no glyphs) must not perturb the scene atlas: same size, the
    // one ref still resolves, its texel unchanged.
    var empty: Atlas = .{ .gpa = gpa, .width = 0, .height = 0, .pixels = try gpa.alloc(u8, 0), .regions = try gpa.alloc(Region, 0) };
    defer empty.deinit();

    var m = try merge(gpa, &atlas, &empty);
    defer m.deinit();
    try testing.expectEqual(atlas.width, m.width);
    try testing.expectEqual(atlas.height, m.height);
    try testing.expectEqual(@as(usize, 1), m.regions.len);
    const uv = m.uv("s.msf", 0).?;
    try testing.expectApproxEqAbs(uv.min[0], atlas.uv("s.msf", 0).?.min[0], 1e-6);
    try testing.expectEqual(f[0], m.pixels[0]);
}
