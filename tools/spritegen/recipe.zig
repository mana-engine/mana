//! The `spritegen` sprite-recipe schema (ADR 0031) and the pure rasterization from a
//! parsed recipe to per-frame RGBA8 pixel buffers. A recipe is genre-neutral data: a
//! palette, a list of frames (each an ordered list of drawing ops over `raster`'s
//! primitives), and named animation clips. It knows nothing about pac/ghost/snake —
//! those are recipe *files* under a game package (invariant #6).
//!
//! Parsing uses `data.zon` (no new dependency); rasterization uses `raster`. Colours
//! are referenced by palette name and resolved here; a fully-transparent palette
//! colour (`a == 0`) acts as the erase colour in `raster` (cuts a hole).

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster.zig");

/// A named palette entry: an 8-bit straight-alpha RGBA colour. Referenced by `name`
/// from an op's colour field.
pub const Color = struct {
    name: []const u8,
    rgba: [4]u8,
};

/// One drawing primitive, tagged by kind. Coordinates are normalized 0..1 over the
/// square canvas (see `raster`). `color` fields name a palette entry. This union is
/// the *entire* genre-neutral vocabulary the tool exposes.
pub const Op = union(enum) {
    disc: struct { cx: f32, cy: f32, r: f32, color: []const u8 },
    wedge: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32, color: []const u8 },
    dome: struct { cx: f32, cy: f32, r: f32, height: f32, bumps: u32, skirt: f32, color: []const u8 },
    eyes: struct {
        cx: f32,
        cy: f32,
        spacing: f32,
        r: f32,
        pupil_r: f32,
        look_x: f32 = 0,
        look_y: f32 = 0,
        white: []const u8,
        pupil: []const u8,
    },
    rect: struct { x: f32, y: f32, w: f32, h: f32, color: []const u8 },
    rounded_rect: struct { x: f32, y: f32, w: f32, h: f32, radius: f32, color: []const u8 },
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: []const u8 },
};

/// One animation frame: an optional label and the ordered ops that draw it (painter's
/// order — later ops composite over earlier ones).
pub const Frame = struct {
    name: []const u8 = "",
    ops: []const Op,
};

/// A named animation clip (ADR 0031, ADR 0033): an ordered list of frame indices played
/// at `fps`, plus optional per-facing phase lists for a directional sprite. Frame indices
/// refer to positions in the recipe's `frames`. Ping-pong/loop behaviour is a consumer
/// (engine) choice, not encoded here.
///
/// `frames` is the non-directional / default phase list (optional if any facing is given
/// — the tool then derives a base from the first present facing). Author a facing to make
/// the sprite directional; OMIT one horizontal facing (`left`/`right`) to have the engine
/// mirror it from its opposite (ADR 0033 §2: "absence is the signal"). Author both to opt
/// out of mirroring for an asymmetric character.
pub const Clip = struct {
    name: []const u8,
    fps: u32,
    frames: []const u32 = &.{},
    up: ?[]const u32 = null,
    down: ?[]const u32 = null,
    left: ?[]const u32 = null,
    right: ?[]const u32 = null,
};

/// A full sprite recipe. `size` is the square canvas edge in pixels. `background`
/// names a palette colour to clear each frame to, or is null for transparent.
pub const Recipe = struct {
    size: u32,
    palette: []const Color,
    background: ?[]const u8 = null,
    frames: []const Frame,
    animations: []const Clip = &.{},
};

/// Errors rasterization can raise beyond allocation: a colour name absent from the
/// palette, a clip frame index out of range, or a degenerate canvas size.
pub const Error = error{ UnknownColor, FrameIndexOutOfRange, EmptyRecipe, EmptyClip } || Allocator.Error;

/// The rasterized output: one RGBA8 buffer per frame (`size*size*4` bytes each),
/// plus the frame edge in pixels. Caller owns it; free with `deinit`.
pub const Rasterized = struct {
    size: u32,
    frames: [][]u8,

    /// Free every frame buffer and the frame slice.
    pub fn deinit(self: *Rasterized, gpa: Allocator) void {
        for (self.frames) |f| gpa.free(f);
        gpa.free(self.frames);
        self.* = undefined;
    }
};

/// Validate `recipe` against the palette/clip references and rasterize every frame to
/// RGBA8. Pure and deterministic: the same recipe always yields byte-identical
/// buffers. Caller owns the result; free with `Rasterized.deinit`.
pub fn rasterize(gpa: Allocator, recipe: Recipe) Error!Rasterized {
    if (recipe.size == 0 or recipe.frames.len == 0) return error.EmptyRecipe;
    try validateClips(recipe);

    const bg: raster.Rgba = if (recipe.background) |name|
        toRgba(try resolve(recipe, name))
    else
        .{ 0, 0, 0, 0 };

    var frames = try gpa.alloc([]u8, recipe.frames.len);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |f| gpa.free(f);
        gpa.free(frames);
    }
    for (recipe.frames, 0..) |frame, fi| {
        var canvas = try raster.Canvas.init(gpa, recipe.size, recipe.size, bg);
        defer canvas.deinit(gpa);
        for (frame.ops) |op| try drawOp(recipe, &canvas, op);
        frames[fi] = try canvas.toRgba8(gpa);
        built += 1;
    }
    return .{ .size = recipe.size, .frames = frames };
}

/// Ensure every clip's frame index — in its base list AND every per-facing phase list
/// (ADR 0033) — is in range (so the engine never indexes past the sheet). Also rejects a
/// clip that names no frames at all (neither `frames` nor any facing), which would carry
/// no phase length. Called before any rasterization work.
fn validateClips(recipe: Recipe) Error!void {
    for (recipe.animations) |clip| {
        var any = clip.frames.len > 0;
        for (clip.frames) |idx| {
            if (idx >= recipe.frames.len) return error.FrameIndexOutOfRange;
        }
        for ([_]?[]const u32{ clip.up, clip.down, clip.left, clip.right }) |facing| {
            const list = facing orelse continue;
            if (list.len > 0) any = true;
            for (list) |idx| {
                if (idx >= recipe.frames.len) return error.FrameIndexOutOfRange;
            }
        }
        if (!any) return error.EmptyClip;
    }
}

/// Look up a palette colour by name, or `error.UnknownColor`.
fn resolve(recipe: Recipe, name: []const u8) Error![4]u8 {
    for (recipe.palette) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.rgba;
    }
    return error.UnknownColor;
}

/// Convert an 8-bit straight-alpha colour to `raster`'s 0..1 float form.
fn toRgba(c: [4]u8) raster.Rgba {
    return .{
        @as(f32, @floatFromInt(c[0])) / 255,
        @as(f32, @floatFromInt(c[1])) / 255,
        @as(f32, @floatFromInt(c[2])) / 255,
        @as(f32, @floatFromInt(c[3])) / 255,
    };
}

/// Dispatch one op to the matching `raster` primitive, resolving colour names.
fn drawOp(recipe: Recipe, canvas: *raster.Canvas, op: Op) Error!void {
    switch (op) {
        .disc => |d| raster.disc(canvas, d.cx, d.cy, d.r, toRgba(try resolve(recipe, d.color))),
        .wedge => |w| raster.wedge(canvas, w.cx, w.cy, w.r, w.a0, w.a1, toRgba(try resolve(recipe, w.color))),
        .dome => |d| raster.dome(canvas, d.cx, d.cy, d.r, d.height, d.bumps, d.skirt, toRgba(try resolve(recipe, d.color))),
        .eyes => |e| raster.eyes(canvas, e.cx, e.cy, e.spacing, e.r, e.pupil_r, e.look_x, e.look_y, toRgba(try resolve(recipe, e.white)), toRgba(try resolve(recipe, e.pupil))),
        .rect => |r| raster.rect(canvas, r.x, r.y, r.w, r.h, toRgba(try resolve(recipe, r.color))),
        .rounded_rect => |r| raster.roundedRect(canvas, r.x, r.y, r.w, r.h, r.radius, toRgba(try resolve(recipe, r.color))),
        .line => |l| raster.line(canvas, l.x0, l.y0, l.x1, l.y1, l.thickness, toRgba(try resolve(recipe, l.color))),
    }
}

// --- Tests ------------------------------------------------------------------------

const data = @import("data");
const testing = std.testing;

/// A minimal, genre-neutral recipe used by the tests below. Two frames of a disc with
/// a widening wedge cut — a generic "chomp", no game vocabulary.
const sample_recipe: [:0]const u8 =
    \\.{
    \\    .size = 16,
    \\    .palette = .{
    \\        .{ .name = "fill", .rgba = .{ 255, 220, 40, 255 } },
    \\        .{ .name = "clear", .rgba = .{ 0, 0, 0, 0 } },
    \\    },
    \\    .frames = .{
    \\        .{ .ops = .{
    \\            .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.45, .color = "fill" } },
    \\        } },
    \\        .{ .ops = .{
    \\            .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.45, .color = "fill" } },
    \\            .{ .wedge = .{ .cx = 0.5, .cy = 0.5, .r = 0.5, .a0 = -30, .a1 = 30, .color = "clear" } },
    \\        } },
    \\    },
    \\    .animations = .{
    \\        .{ .name = "chomp", .fps = 8, .frames = .{ 0, 1, 0 } },
    \\    },
    \\}
;

test "recipe: parses and rasterizes to per-frame RGBA8" {
    const parsed = try data.zon.parse(Recipe, testing.allocator, sample_recipe);
    defer data.zon.free(testing.allocator, parsed);
    var out = try rasterize(testing.allocator, parsed);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), out.frames.len);
    try testing.expectEqual(@as(usize, 16 * 16 * 4), out.frames[0].len);
    // The wedge in frame 1 erased the centre-right, so frame 1 differs from frame 0.
    try testing.expect(!std.mem.eql(u8, out.frames[0], out.frames[1]));
}

test "recipe: rasterization is deterministic (byte-identical across runs)" {
    const parsed = try data.zon.parse(Recipe, testing.allocator, sample_recipe);
    defer data.zon.free(testing.allocator, parsed);
    var a = try rasterize(testing.allocator, parsed);
    defer a.deinit(testing.allocator);
    var b = try rasterize(testing.allocator, parsed);
    defer b.deinit(testing.allocator);
    for (a.frames, b.frames) |fa, fb| try testing.expectEqualSlices(u8, fa, fb);
}

test "recipe: an unknown colour name is an error" {
    const bad: [:0]const u8 =
        \\.{
        \\    .size = 8,
        \\    .palette = .{ .{ .name = "fill", .rgba = .{ 1, 2, 3, 255 } } },
        \\    .frames = .{ .{ .ops = .{ .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.4, .color = "missing" } } } } },
        \\}
    ;
    const parsed = try data.zon.parse(Recipe, testing.allocator, bad);
    defer data.zon.free(testing.allocator, parsed);
    try testing.expectError(error.UnknownColor, rasterize(testing.allocator, parsed));
}

test "recipe: a directional clip's per-facing frames are validated and rasterized" {
    const dir: [:0]const u8 =
        \\.{
        \\    .size = 8,
        \\    .palette = .{
        \\        .{ .name = "fill", .rgba = .{ 255, 220, 40, 255 } },
        \\        .{ .name = "clear", .rgba = .{ 0, 0, 0, 0 } },
        \\    },
        \\    .frames = .{
        \\        .{ .ops = .{ .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.45, .color = "fill" } } } },
        \\        .{ .ops = .{
        \\            .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.45, .color = "fill" } },
        \\            .{ .wedge = .{ .cx = 0.5, .cy = 0.5, .r = 0.5, .a0 = -30, .a1 = 30, .color = "clear" } },
        \\        } },
        \\    },
        \\    .animations = .{
        \\        .{ .name = "chomp", .fps = 8, .up = .{ 0, 1 }, .down = .{ 1, 0 }, .right = .{ 0, 1 } },
        \\    },
        \\}
    ;
    const parsed = try data.zon.parse(Recipe, testing.allocator, dir);
    defer data.zon.free(testing.allocator, parsed);
    var out = try rasterize(testing.allocator, parsed);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.frames.len);
    // left is omitted (mirrored from right at render); the clip is still valid.
    try testing.expect(parsed.animations[0].left == null);
}

test "recipe: a directional facing frame index out of range is an error" {
    const bad: [:0]const u8 =
        \\.{
        \\    .size = 8,
        \\    .palette = .{ .{ .name = "fill", .rgba = .{ 1, 2, 3, 255 } } },
        \\    .frames = .{ .{ .ops = .{ .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.4, .color = "fill" } } } } },
        \\    .animations = .{ .{ .name = "x", .fps = 4, .right = .{ 0, 9 } } },
        \\}
    ;
    const parsed = try data.zon.parse(Recipe, testing.allocator, bad);
    defer data.zon.free(testing.allocator, parsed);
    try testing.expectError(error.FrameIndexOutOfRange, rasterize(testing.allocator, parsed));
}

test "recipe: a clip that names no frames at all is an error" {
    const bad: [:0]const u8 =
        \\.{
        \\    .size = 8,
        \\    .palette = .{ .{ .name = "fill", .rgba = .{ 1, 2, 3, 255 } } },
        \\    .frames = .{ .{ .ops = .{ .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.4, .color = "fill" } } } } },
        \\    .animations = .{ .{ .name = "empty", .fps = 4 } },
        \\}
    ;
    const parsed = try data.zon.parse(Recipe, testing.allocator, bad);
    defer data.zon.free(testing.allocator, parsed);
    try testing.expectError(error.EmptyClip, rasterize(testing.allocator, parsed));
}

test "recipe: a clip frame index out of range is an error" {
    const bad: [:0]const u8 =
        \\.{
        \\    .size = 8,
        \\    .palette = .{ .{ .name = "fill", .rgba = .{ 1, 2, 3, 255 } } },
        \\    .frames = .{ .{ .ops = .{ .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.4, .color = "fill" } } } } },
        \\    .animations = .{ .{ .name = "x", .fps = 4, .frames = .{ 0, 5 } } },
        \\}
    ;
    const parsed = try data.zon.parse(Recipe, testing.allocator, bad);
    defer data.zon.free(testing.allocator, parsed);
    try testing.expectError(error.FrameIndexOutOfRange, rasterize(testing.allocator, parsed));
}
