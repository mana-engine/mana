//! `spritegen` — a genre-neutral procedural sprite generator (ADR 0031, Lane A).
//!
//! Reads a ZON **sprite recipe** (a palette, per-frame lists of generic primitives —
//! disc, wedge, dome, eyes, rect, rounded-rect, line — and named animation clips) and
//! deterministically rasterizes it into two DERIVED artifacts in an output dir:
//!   - `<name>.msf`         — the MSF2 sprite-sheet asset (the engine decodes it)
//!   - `<name>_preview.png` — a human-viewable montage of the frames over a checkerboard
//!
//! Neither is committed (they are pure functions of the recipe — invariant #1; the
//! recipe is the source of truth). The tool knows NO game vocabulary: "pac"/"ghost"/
//! "food" are recipe files under a game package (invariant #6).
//!
//! Run: `mise run spritegen -- <recipe.zon> <out-dir>` (cross-platform). See
//! `tools/spritegen/README.md` for the recipe grammar and the view command.

const std = @import("std");
const data = @import("data");
const recipe_mod = @import("recipe.zig");
// The MSF encoder now lives in `data` (the file layer) so the engine's loader decodes
// the exact same format definition (ADR 0031 §2); this tool is one of its two clients.
const format = data.msf;
const montage = @import("montage.zig");

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
        try out.writeAll("usage: spritegen <recipe.zon> <out-dir>\n");
        try out.flush();
        return error.InvalidUsage;
    }
    const recipe_path = args[1];
    const out_dir = args[2];

    try generate(out, io, gpa, arena, recipe_path, out_dir);
    try out.flush();
}

/// Load `recipe_path`, rasterize it, and write `<name>.msf` + `<name>_preview.png`
/// into `out_dir` (created if absent). `name` is the recipe's filename stem. Prints
/// one summary line on success (quiet-on-success). Errors propagate.
fn generate(out: *Io.Writer, io: Io, gpa: Allocator, arena: Allocator, recipe_path: []const u8, out_dir: []const u8) !void {
    const src = try Io.Dir.cwd().readFileAllocOptions(io, recipe_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);

    const recipe = data.zon.parse(recipe_mod.Recipe, gpa, src) catch |err| {
        try out.print("spritegen: cannot parse recipe '{s}': {s}\n", .{ recipe_path, @errorName(err) });
        return err;
    };
    defer data.zon.free(gpa, recipe);

    var raster = try recipe_mod.rasterize(gpa, recipe);
    defer raster.deinit(gpa);

    try Io.Dir.cwd().createDirPath(io, out_dir);
    const stem = std.fs.path.stem(recipe_path);

    // 1. The MSF sheet asset.
    const clips = try toFormatClips(arena, recipe.animations);
    const sheet: format.Sheet = .{
        .width = @intCast(raster.size),
        .height = @intCast(raster.size),
        .frames = raster.frames,
        .clips = clips,
    };
    const msf = try format.encode(gpa, sheet);
    defer gpa.free(msf);
    const msf_name = try std.fmt.allocPrint(arena, "{s}.msf", .{stem});
    const msf_path = try std.fs.path.join(arena, &.{ out_dir, msf_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = msf_path, .data = msf });

    // 2. The human-viewable preview PNG.
    var preview = try montage.build(gpa, raster.size, raster.frames);
    defer preview.deinit(gpa);
    const png = try data.png.encode(gpa, preview.width, preview.height, preview.rgba);
    defer gpa.free(png);
    const png_name = try std.fmt.allocPrint(arena, "{s}_preview.png", .{stem});
    const png_path = try std.fs.path.join(arena, &.{ out_dir, png_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = png });

    try out.print(
        "spritegen: '{s}' — {d} frames, {d}x{d} px, {d} clips → {s}, {s}\n",
        .{ recipe_path, raster.frames.len, raster.size, raster.size, recipe.animations.len, msf_path, png_path },
    );
}

/// Narrow the recipe's clips (`fps`/frame indices as `u32`) to the MSF wire types
/// (`u16`), carrying the per-facing phase lists through (ADR 0033). A directional clip
/// that names no base `frames` derives one from the first present facing (order right,
/// down, up, left) so a never-moved entity has a sensible default pose. Allocated in
/// `arena` (freed with the whole arena at exit).
fn toFormatClips(arena: Allocator, clips: []const recipe_mod.Clip) Allocator.Error![]format.Clip {
    const out = try arena.alloc(format.Clip, clips.len);
    for (clips, out) |c, *o| {
        // MSF facing order is up, down, left, right (data.msf.Facing); the recipe names
        // them individually. null ⇒ that facing is absent (mirrored/fallback at render).
        const facings: [4]?[]const u16 = .{
            try narrow(arena, c.up),
            try narrow(arena, c.down),
            try narrow(arena, c.left),
            try narrow(arena, c.right),
        };
        // Base = the explicit `frames`, else the first authored facing in a fixed
        // preference (right, down, up, left) so its phase length drives the cursor.
        const base = if (c.frames.len > 0)
            (try narrow(arena, c.frames)).?
        else
            facings[3] orelse facings[1] orelse facings[0] orelse facings[2] orelse &.{};
        o.* = .{ .name = c.name, .fps = @intCast(c.fps), .frames = base, .facings = facings };
    }
    return out;
}

/// Narrow an optional `u32` frame-index list to `u16`, allocated in `arena`; null stays
/// null (an absent facing). Used by `toFormatClips`.
fn narrow(arena: Allocator, list: ?[]const u32) Allocator.Error!?[]const u16 {
    const src = list orelse return null;
    const dst = try arena.alloc(u16, src.len);
    for (src, dst) |s, *d| d.* = @intCast(s);
    return dst;
}

test {
    // Pull the sibling modules' tests into this compilation unit (main's `pub fn main`
    // is not analyzed under `zig build test`, so reference them explicitly).
    _ = @import("raster.zig");
    _ = @import("recipe.zig");
    _ = @import("montage.zig");
    // The MSF format tests now live with the codec in `data.msf` (run by the `data`
    // module's test binary), so they are not re-pulled here.
}

const testing = std.testing;

test "toFormatClips: carries facings through and derives the base from the first present facing" {
    const clips = [_]recipe_mod.Clip{
        // Directional, no explicit base: up/down/right authored, left omitted.
        .{ .name = "chomp", .fps = 12, .up = &.{ 4, 5 }, .down = &.{ 8, 9 }, .right = &.{ 0, 1 } },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try toFormatClips(arena_state.allocator(), &clips);

    try testing.expectEqual(@as(usize, 1), out.len);
    // Base derived from `right` (preference order right, down, up, left).
    try testing.expectEqualSlices(u16, &.{ 0, 1 }, out[0].frames);
    // Facings land in MSF order (up, down, left, right); left stays absent (mirrored).
    try testing.expectEqualSlices(u16, &.{ 4, 5 }, out[0].facings[@intFromEnum(format.Facing.up)].?);
    try testing.expectEqualSlices(u16, &.{ 8, 9 }, out[0].facings[@intFromEnum(format.Facing.down)].?);
    try testing.expect(out[0].facings[@intFromEnum(format.Facing.left)] == null);
    try testing.expectEqualSlices(u16, &.{ 0, 1 }, out[0].facings[@intFromEnum(format.Facing.right)].?);
}
