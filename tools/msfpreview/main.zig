//! `msfpreview` — a headless animated previewer for `.msf` sprite sheets (issue #129
//! phase 1; ADR 0031 §3, ADR 0033). Given a generated `.msf`, it renders every clip's
//! authored AND mirror-inferred facings, frames in phase order, into one filmstrip PNG —
//! the deterministic, dependency-free, CI-friendly way to SEE what a sheet contains (the
//! montage idea, extended from one row of raw frames to a grid of clip×facing rows) without
//! a window or the interactive editor (that stays a separate, windowed-tooling follow-up —
//! issue #129 phase 2, not built here).
//!
//! It reuses, rather than reimplements, the exact runtime rendering path: `layout.zig`
//! calls the SAME `engine.sprite.resolveFacing` that `render.projectSprites` calls to pick
//! a facing's phase list and decide the mirror flag, `engine.sprite.buildAtlas` packs the
//! sheet's raw frames exactly like the engine does, and `engine.gpu.captureFrame` — the
//! same CPU atlas-sampling rasterizer `--render-play-frame` uses — draws the pixels. So a
//! facing/mirror/sampling bug shows up here exactly as it would in `--play` (the #125
//! lesson this tool answers: a per-frame facing-flip would have been obvious in a preview).
//! The checkerboard-compositing finish reuses `tools/spritegen/montage.zig`.
//!
//! TODO(#128): tint/blink variant preview depends on #128 (in flight) and is NOT built in
//! this phase — see the seam noted in `layout.zig`'s module doc and `README.md`.
//!
//! Run: `mise run msfpreview -- <sheet.msf> <out-dir>` (cross-platform).

const std = @import("std");
const data = @import("data");
const engine = @import("engine");
const sprite = engine.sprite;
const gpu = engine.gpu;
const layout = @import("layout.zig");
// Reused, not reinvented (extends ADR 0031 §3's montage idea): the checkerboard
// compositing helper lives with spritegen's existing montage code (wired in `build.zig`
// as a second module root over the same file — Zig 0.16 forbids a relative import
// reaching outside this module's own root).
const montage = @import("montage");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try out.writeAll("usage: msfpreview <sheet.msf> <out-dir>\n");
        try out.flush();
        return error.InvalidUsage;
    }
    const msf_path = args[1];
    const out_dir = args[2];

    try generate(out, io, gpa, arena, msf_path, out_dir);
    try out.flush();
}

/// Decode `msf_path`, lay its clips out into a filmstrip grid, render it via the real
/// engine sprite pipeline, and write `<stem>_filmstrip.png` into `out_dir` (created if
/// absent). Prints one summary line on success (quiet-on-success). Errors propagate.
fn generate(out: *Io.Writer, io: Io, gpa: Allocator, arena: Allocator, msf_path: []const u8, out_dir: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAllocOptions(io, msf_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(bytes);
    const sheet = try data.msf.decode(gpa, bytes);
    const stem = std.fs.path.stem(msf_path);

    // A one-entry `SheetStore` so `sprite.buildAtlas` packs this sheet's frames exactly as
    // the engine would (never a hand-rolled atlas). `store.deinit` owns and frees `sheet`.
    var store: sprite.SheetStore = .{ .gpa = gpa };
    defer store.deinit();
    try store.entries.append(gpa, .{ .ref = stem, .sheet = sheet });

    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var lay = try layout.build(gpa, &sheet);
    defer lay.deinit(gpa);

    const quads = try buildQuads(gpa, lay, &atlas, stem);
    defer gpa.free(quads);

    // Transparent clear: `captureFrame` composites straight-alpha frames over it, and
    // `compositeOverCheckerboard` un-premultiplies + lays the result over a checkerboard
    // (so transparency reads, ADR 0031 §3) as a second, CPU-only pass.
    const clear = [4]f32{ 0, 0, 0, 0 };
    const raw = try gpu.captureFrame(gpa, lay.width, lay.height, &.{}, quads, atlas.pixels, atlas.width, atlas.height, clear);
    defer gpa.free(raw);
    var composited = try montage.compositeOverCheckerboard(gpa, lay.width, lay.height, raw);
    defer composited.deinit(gpa);

    try Io.Dir.cwd().createDirPath(io, out_dir);
    const png_bytes = try data.png.encode(gpa, composited.width, composited.height, composited.rgba);
    defer gpa.free(png_bytes);
    const png_name = try std.fmt.allocPrint(arena, "{s}_filmstrip.png", .{stem});
    const png_path = try std.fs.path.join(arena, &.{ out_dir, png_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = png_bytes });

    try out.print(
        "msfpreview: '{s}' — {d} clips, {d} frames, {d}x{d} px/frame, {d}x{d} filmstrip → {s}\n",
        .{ msf_path, sheet.clips.len, sheet.frames.len, sheet.width, sheet.height, lay.width, lay.height, png_path },
    );
}

/// Turn `lay`'s placed cells into `gpu.SpriteQuad`s over the whole `lay.width`×`lay.height`
/// canvas, looking each cell's sheet frame up in `atlas` (packed under `ref`) and swapping
/// the UV `u` endpoints for a mirrored cell — the exact same swap
/// `render.projectSprites` performs for an inferred facing (ADR 0033 §2), so the mirror the
/// null-backend rasterizer draws here matches runtime pixel-for-pixel. Caller owns the
/// result. Errors: `error.OutOfMemory`, `error.FrameNotInAtlas` (a `layout` bug: every
/// emitted frame index came from this very sheet, packed into the very same atlas).
fn buildQuads(gpa: Allocator, lay: layout.Layout, atlas: *const sprite.Atlas, ref: []const u8) ![]gpu.SpriteQuad {
    const quads = try gpa.alloc(gpu.SpriteQuad, lay.cells.len);
    errdefer gpa.free(quads);
    const cw: f32 = @floatFromInt(lay.width);
    const ch: f32 = @floatFromInt(lay.height);
    const fw: f32 = @floatFromInt(lay.frame_w);
    const fh: f32 = @floatFromInt(lay.frame_h);
    for (lay.cells, quads) |cell, *q| {
        const region = atlas.uv(ref, cell.frame) orelse return error.FrameNotInAtlas;
        var uv_min = region.min;
        var uv_max = region.max;
        if (cell.mirror_x) std.mem.swap(f32, &uv_min[0], &uv_max[0]);
        const x0f: f32 = @floatFromInt(cell.x0);
        const y0f: f32 = @floatFromInt(cell.y0);
        q.* = .{
            .center = .{ (2 * x0f + fw) / cw - 1, (2 * y0f + fh) / ch - 1 },
            .half = .{ fw / cw, fh / ch },
            .uv_min = uv_min,
            .uv_max = uv_max,
            .tint = .{ 1, 1, 1 },
        };
    }
    return quads;
}

test {
    // Pull the sibling module's tests into this compilation unit (main's `pub fn main`/
    // `generate` are not analyzed under `zig build test`, so reference them explicitly —
    // mirrors `tools/spritegen/main.zig`'s own test block).
    _ = layout;
    _ = montage;
}

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

/// The pixel `(x,y)` in a `width`-wide, tightly-packed RGBA8 buffer matches `expected`.
fn expectPixel(rgba: []const u8, width: u32, x: u32, y: u32, expected: [4]u8) !void {
    const i = (@as(usize, y) * width + x) * 4;
    try testing.expectEqualSlices(u8, &expected, rgba[i .. i + 4]);
}

test "msfpreview: end-to-end — dimensions and a mirrored pixel match the engine's own facing/mirror resolution" {
    const gpa = testing.allocator;
    // A 2x1 frame, asymmetric (px(0,0) red, px(1,0) blue), so mirroring is visibly
    // provable — a symmetric frame couldn't distinguish "mirrored" from "not".
    const w: u16 = 2;
    const h: u16 = 1;
    const red_blue = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const clips = [_]data.msf.Clip{.{
        .name = "walk",
        .fps = 4,
        .frames = &.{0},
        .facings = .{ null, null, null, &.{0} }, // right authored; left absent → mirrored
    }};
    const sheet: data.msf.Sheet = .{ .width = w, .height = h, .frames = &.{&red_blue}, .clips = &clips };

    // encode→decode so the store owns freeable slices, matching `sprite.loadForScene`.
    const bytes = try data.msf.encode(gpa, sheet);
    defer gpa.free(bytes);
    const owned = try data.msf.decode(gpa, bytes);

    var store: sprite.SheetStore = .{ .gpa = gpa };
    defer store.deinit();
    try store.entries.append(gpa, .{ .ref = "s", .sheet = owned });

    var atlas = try sprite.buildAtlas(gpa, &store);
    defer atlas.deinit();

    var lay = try layout.build(gpa, &owned);
    defer lay.deinit(gpa);
    // One clip, directional (only `right` authored) ⇒ 4 rows (up, down, left, right).
    try testing.expectEqual(@as(usize, 1), lay.rows_per_clip.len);
    try testing.expectEqual(@as(u32, 4), lay.rows_per_clip[0]);
    try testing.expectEqual(layout.gutter + (@as(u32, w) + layout.gutter), lay.width);

    const quads = try buildQuads(gpa, lay, &atlas, "s");
    defer gpa.free(quads);
    const clear = [4]f32{ 0, 0, 0, 0 };
    const raw = try gpu.captureFrame(gpa, lay.width, lay.height, &.{}, quads, atlas.pixels, atlas.width, atlas.height, clear);
    defer gpa.free(raw);

    // Row order up(0), down(1), left(2), right(3); row y0 = gutter + row*(h+gutter).
    const right_y = layout.gutter + 3 * (@as(u32, h) + layout.gutter);
    const left_y = layout.gutter + 2 * (@as(u32, h) + layout.gutter);
    const x0 = layout.gutter;
    // Unmirrored `right` row: local px(0,0) samples the frame's own px(0,0) — red.
    try expectPixel(raw, lay.width, x0, right_y, .{ 255, 0, 0, 255 });
    // Mirrored `left` row: local px(0,0) samples the frame's px(1,0) instead — blue.
    try expectPixel(raw, lay.width, x0, left_y, .{ 0, 0, 255, 255 });

    // The final composited (checkerboard-backed) image stays the same size and keeps the
    // fully-opaque pixels unchanged (no checkerboard shows through an opaque frame).
    var composited = try montage.compositeOverCheckerboard(gpa, lay.width, lay.height, raw);
    defer composited.deinit(gpa);
    try testing.expectEqual(lay.width, composited.width);
    try testing.expectEqual(lay.height, composited.height);
    try expectPixel(composited.rgba, lay.width, x0, right_y, .{ 255, 0, 0, 255 });
    try expectPixel(composited.rgba, lay.width, x0, left_y, .{ 0, 0, 255, 255 });
}
