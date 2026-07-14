//! Pure layout math for `msfpreview` (issue #129 phase 1; ADR 0031 §3, ADR 0033): turn a
//! decoded `.msf` sheet into a grid of placed cells — one row per clip×facing, frames in
//! phase order — using the EXACT engine facing/mirror resolution (`engine.sprite.
//! resolveFacing`), so the preview's rows are never a second, drifting reimplementation of
//! that logic. This module only computes WHERE each frame goes (a pixel rect) and WHICH
//! sheet frame + mirror flag fills it; `main.zig` turns that into `gpu.SpriteQuad`s and
//! `gpu.captureFrame` (the real CPU atlas-sampling rasterizer) draws the actual pixels.
//!
//! Row order (directional clips): `up`, `down`, `left`, `right` (the `data.msf.Facing`
//! wire order) — an authored facing is used as-authored; a missing horizontal facing (the
//! "absence is the signal" mirror, ADR 0033 §2) draws its opposite's frames with
//! `mirror_x = true`, exactly as `render.projectSprites` would draw it at runtime. A
//! NON-directional clip (no facing authored at all) gets a single row: its base `frames`
//! list. A sheet with no clips at all falls back to one row listing every raw frame in
//! sheet order, so an empty-clip `.msf` still previews something rather than a blank image.
//!
//! TODO(#128): once tint/blink lands, a variant dimension slots in here as extra columns
//! or a parallel canvas — deliberately not built in this phase (see the PR/README note).

const std = @import("std");
const data = @import("data");
const engine = @import("engine");
const sprite = engine.sprite;

const Allocator = std.mem.Allocator;

/// Pixel gutter between adjacent cells and around the grid border (matches
/// `tools/spritegen/montage.zig`'s convention).
pub const gutter: u32 = 4;
/// Extra pixel gap appended after each clip's row block, on top of the ordinary
/// inter-row `gutter`, so clip boundaries are visually obvious in the filmstrip.
pub const clip_gap: u32 = 8;

/// One placed frame: its top-left pixel in the output canvas, which sheet frame to draw
/// there, and whether to X-flip its UVs (ADR 0033 §2's mirror). Every cell is
/// `frame_w`×`frame_h` (a sheet's frame grid is uniform, ADR 0032 §1).
pub const Cell = struct {
    x0: u32,
    y0: u32,
    frame: u16,
    mirror_x: bool,
};

/// The computed grid: overall canvas size, every placed cell, and how many rows each clip
/// (in `sheet.clips` order, or one synthetic "clip" if `sheet.clips` is empty) occupied —
/// the row count alone proves a directional clip got all four facings.
pub const Layout = struct {
    width: u32,
    height: u32,
    frame_w: u32,
    frame_h: u32,
    cells: []Cell,
    rows_per_clip: []u32,

    /// Free the owned `cells` and `rows_per_clip` slices.
    pub fn deinit(self: *Layout, gpa: Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.rows_per_clip);
        self.* = undefined;
    }
};

/// Lay `sheet`'s clips out into a filmstrip grid (see module docs for the row rules).
/// Pure and deterministic — the same sheet always yields the same layout. Caller owns the
/// result (`Layout.deinit`). Errors: `error.OutOfMemory`.
pub fn build(gpa: Allocator, sheet: *const data.msf.Sheet) Allocator.Error!Layout {
    const fw: u32 = sheet.width;
    const fh: u32 = sheet.height;

    var cells: std.ArrayList(Cell) = .empty;
    errdefer cells.deinit(gpa);

    const clip_count = @max(sheet.clips.len, 1); // the no-clips fallback is one synthetic row
    const rows_per_clip = try gpa.alloc(u32, clip_count);
    errdefer gpa.free(rows_per_clip);

    var y: u32 = gutter;
    var max_row_end_x: u32 = gutter;

    if (sheet.clips.len == 0) {
        // No clips authored at all: show every raw frame in sheet order so the sheet
        // still previews something instead of a blank canvas.
        const frames = try gpa.alloc(u16, sheet.frames.len);
        defer gpa.free(frames);
        for (frames, 0..) |*f, i| f.* = @intCast(i);
        const end_x = try placeRow(gpa, &cells, frames, false, y, fw);
        max_row_end_x = @max(max_row_end_x, end_x);
        rows_per_clip[0] = 1;
    } else {
        for (sheet.clips, 0..) |clip, ci| {
            const directional = clip.facings[0] != null or clip.facings[1] != null or
                clip.facings[2] != null or clip.facings[3] != null;
            if (directional) {
                for ([_]data.msf.Facing{ .up, .down, .left, .right }) |f| {
                    const resolved = sprite.resolveFacing(&clip, f);
                    const end_x = try placeRow(gpa, &cells, resolved.frames, resolved.mirror_x, y, fw);
                    max_row_end_x = @max(max_row_end_x, end_x);
                    y += fh + gutter;
                }
                rows_per_clip[ci] = 4;
            } else {
                const resolved = sprite.resolveFacing(&clip, null);
                const end_x = try placeRow(gpa, &cells, resolved.frames, resolved.mirror_x, y, fw);
                max_row_end_x = @max(max_row_end_x, end_x);
                y += fh + gutter;
                rows_per_clip[ci] = 1;
            }
            y += clip_gap;
        }
    }

    return .{
        .width = max_row_end_x,
        .height = y,
        .frame_w = fw,
        .frame_h = fh,
        .cells = try cells.toOwnedSlice(gpa),
        .rows_per_clip = rows_per_clip,
    };
}

/// Append one row's cells (`frames`, in phase order, left to right) at pixel row `y`; the
/// whole row shares `mirror_x` (a facing is mirrored or not, never per-frame within it).
/// Returns the pixel x just past the last placed cell, used to size the canvas width.
fn placeRow(gpa: Allocator, cells: *std.ArrayList(Cell), frames: []const u16, mirror_x: bool, y: u32, fw: u32) Allocator.Error!u32 {
    var x: u32 = gutter;
    for (frames) |frame| {
        try cells.append(gpa, .{ .x0 = x, .y0 = y, .frame = frame, .mirror_x = mirror_x });
        x += fw + gutter;
    }
    return x;
}

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "layout: a directional clip gets 4 rows (up, down, left, right); absent left mirrors right" {
    const clip: data.msf.Clip = .{
        .name = "chomp",
        .fps = 12,
        .frames = &.{},
        .facings = .{ &.{ 2, 3 }, &.{ 4, 5 }, null, &.{ 0, 1 } }, // up, down, left(absent), right
    };
    const clips = [_]data.msf.Clip{clip};
    const sheet: data.msf.Sheet = .{ .width = 8, .height = 8, .frames = &.{}, .clips = &clips };

    var lay = try build(testing.allocator, &sheet);
    defer lay.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), lay.rows_per_clip.len);
    try testing.expectEqual(@as(u32, 4), lay.rows_per_clip[0]);
    // Every row has 2 frames ⇒ canvas width = gutter + 2*(8+gutter).
    try testing.expectEqual(gutter + 2 * (8 + gutter), lay.width);
    try testing.expectEqual(@as(usize, 8), lay.cells.len); // 4 rows × 2 frames

    // Row order is up(0), down(1), left(2), right(3); the left row's y0 is the 3rd row.
    const left_y = gutter + 2 * (8 + gutter);
    var left_cells: [2]Cell = undefined;
    var n: usize = 0;
    for (lay.cells) |c| {
        if (c.y0 == left_y) {
            left_cells[n] = c;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), n);
    // Left is inferred from right: same frame indices, but mirrored.
    try testing.expectEqual(@as(u16, 0), left_cells[0].frame);
    try testing.expectEqual(@as(u16, 1), left_cells[1].frame);
    try testing.expect(left_cells[0].mirror_x);
    try testing.expect(left_cells[1].mirror_x);
}

test "layout: a non-directional clip gets exactly one row, unmirrored" {
    const clip: data.msf.Clip = .{ .name = "idle", .fps = 4, .frames = &.{ 0, 1, 2 } };
    const clips = [_]data.msf.Clip{clip};
    const sheet: data.msf.Sheet = .{ .width = 4, .height = 4, .frames = &.{}, .clips = &clips };

    var lay = try build(testing.allocator, &sheet);
    defer lay.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), lay.rows_per_clip[0]);
    try testing.expectEqual(@as(usize, 3), lay.cells.len);
    for (lay.cells) |c| try testing.expect(!c.mirror_x);
}

test "layout: a sheet with no clips falls back to one row of every raw frame" {
    const px = [_]u8{ 1, 2, 3, 4 };
    const frames = [_][]const u8{ &px, &px, &px };
    const sheet: data.msf.Sheet = .{ .width = 1, .height = 1, .frames = &frames, .clips = &.{} };

    var lay = try build(testing.allocator, &sheet);
    defer lay.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), lay.rows_per_clip.len);
    try testing.expectEqual(@as(u32, 1), lay.rows_per_clip[0]);
    try testing.expectEqual(@as(usize, 3), lay.cells.len);
    for (lay.cells, 0..) |c, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), c.frame);
        try testing.expect(!c.mirror_x);
    }
}

test "layout: canvas height grows by frame height + gutter per row, plus a clip gap per clip" {
    const clip_a: data.msf.Clip = .{ .name = "a", .fps = 1, .frames = &.{0} }; // 1 row
    const clip_b: data.msf.Clip = .{
        .name = "b",
        .fps = 1,
        .frames = &.{},
        .facings = .{ &.{0}, &.{0}, &.{0}, &.{0} }, // 4 rows (directional)
    };
    const clips = [_]data.msf.Clip{ clip_a, clip_b };
    const sheet: data.msf.Sheet = .{ .width = 4, .height = 4, .frames = &.{}, .clips = &clips };

    var lay = try build(testing.allocator, &sheet);
    defer lay.deinit(testing.allocator);

    // gutter (top) + 1 row*(4+gutter) + clip_gap + 4 rows*(4+gutter) + clip_gap.
    const expected = gutter + 1 * (4 + gutter) + clip_gap + 4 * (4 + gutter) + clip_gap;
    try testing.expectEqual(expected, lay.height);
    try testing.expectEqual(@as(u32, 1), lay.rows_per_clip[0]);
    try testing.expectEqual(@as(u32, 4), lay.rows_per_clip[1]);
}
