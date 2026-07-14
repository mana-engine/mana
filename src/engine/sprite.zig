//! Sprite runtime (ADR 0031 §1-2; issue #113 phase 2): the engine-side, GPU-free half
//! that (a) loads the `.msf` sheets a scene's `Sprite` components reference and (b)
//! advances each entity's `AnimationState` cursor from WALL-CLOCK elapsed time — never a
//! sim tick. Both halves are cosmetic and hash-excluded (the physics/VFX invariant:
//! "cosmetic and excluded from the state hash"; ADR 0031 §1): `advance` reads real
//! elapsed time and writes only the unhashed `AnimationState` column, so it can never
//! perturb `World.stateHash`.
//!
//! This is the deterministic, unit-testable foundation the Vulkan textured-quad pipeline
//! builds on: uploading a decoded sheet to the GPU and sampling it in `--play` is a
//! separate lane (issue #113 phase 2b). Kept pure/GPU-free so it is exercised by the
//! default (null-backend) gate, exactly like `render.project` and `animation.clipPosition`.

const std = @import("std");
const data = @import("data");
const animation = @import("animation.zig");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const msf = data.msf;

/// Subdirectory (relative to a sheet reference's own directory) that holds DERIVED sheet
/// artifacts (ADR 0031 §2): the recipe `.zon` is committed, but the generated `.msf`
/// (and preview) live under `<recipe-dir>/generated/` and are gitignored
/// (`**/sprites/generated/`, built by `mise run assets`). A `Sprite.sheet` reference such
/// as `"sprites/pac.msf"` therefore resolves on disk to `<pkg>/sprites/generated/pac.msf`.
/// Centralised here so the convention has a single home.
pub const generated_subdir = "generated";

/// A decoded sheet keyed by the `Sprite.sheet` reference it was loaded under. Owns its
/// decoded `msf.Sheet` (frames + clip table), freed by the owning `SheetStore`.
const Entry = struct {
    /// The `Sprite.sheet` reference (e.g. `"sprites/pac.msf"`); borrowed from the world's
    /// `Sprite` component, whose backing storage outlives the store.
    ref: []const u8,
    sheet: msf.Sheet,
};

/// Caches every distinct `.msf` sheet a world's `Sprite` components reference, decoded
/// once at load and keyed by the reference string. The store owns the decoded sheets;
/// reference keys are borrowed from the world (which must outlive the store).
pub const SheetStore = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    /// Free every decoded sheet and the entry list. Reference keys are borrowed and not
    /// freed here.
    pub fn deinit(self: *SheetStore) void {
        for (self.entries.items) |*e| msf.free(self.gpa, e.sheet);
        self.entries.deinit(self.gpa);
    }

    /// The decoded sheet for `ref` (a `Sprite.sheet` reference), or null if none is
    /// loaded under that key. Borrowed — valid until `deinit`.
    pub fn get(self: *const SheetStore, ref: []const u8) ?*const msf.Sheet {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.ref, ref)) return &e.sheet;
        }
        return null;
    }

    /// Number of distinct sheets loaded.
    pub fn count(self: *const SheetStore) usize {
        return self.entries.items.len;
    }
};

/// Resolve a `Sprite.sheet` reference to its on-disk DERIVED artifact path (see
/// `generated_subdir`): `<pkg>/<dir(ref)>/generated/<basename(ref)>`. Reference paths use
/// POSIX `/` separators (a content convention); the result is joined with the platform
/// separator. Caller owns the returned path. Errors: `error.OutOfMemory`.
pub fn resolvePath(gpa: Allocator, pkg: []const u8, ref: []const u8) Allocator.Error![]u8 {
    const dir = std.fs.path.dirnamePosix(ref) orelse "";
    const base = std.fs.path.basenamePosix(ref);
    return std.fs.path.join(gpa, &.{ pkg, dir, generated_subdir, base });
}

/// Load and decode every distinct sheet referenced by `world`'s `Sprite` components into
/// a fresh `SheetStore` (issue #113 phase 2, item 2). Each reference is resolved to its
/// generated artifact (`resolvePath`) relative to `base` (the runtime passes
/// `Io.Dir.cwd()`), read via `io`, and decoded with `data.msf`; distinct references are
/// loaded once. A referenced sheet that does not exist on disk is skipped with a warning
/// (its entities hold frame 0), so a package whose assets have not been generated still
/// runs — `mise run assets` produces them. Mirrors `scene.loadWorldFromFile`'s
/// `(gpa, io, base, …)` file-loading shape. Caller owns the store (`deinit`). Errors: file
/// read errors other than not-found, `msf.DecodeError`, `error.OutOfMemory`.
pub fn loadForWorld(gpa: Allocator, io: Io, base: Io.Dir, pkg: []const u8, world: *World) !SheetStore {
    var store: SheetStore = .{ .gpa = gpa };
    errdefer store.deinit();
    for (world.sprites.slice()) |sprite| {
        if (store.get(sprite.sheet) != null) continue;
        const path = try resolvePath(gpa, pkg, sprite.sheet);
        defer gpa.free(path);
        const read = base.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
        const bytes = read catch |err| switch (err) {
            error.FileNotFound => {
                std.log.scoped(.sprite).warn("sheet not found: {s} (`mise run assets`)", .{path});
                continue;
            },
            else => return err,
        };
        defer gpa.free(bytes);
        const sheet = try msf.decode(gpa, bytes);
        try store.entries.append(gpa, .{ .ref = sprite.sheet, .sheet = sheet });
    }
    return store;
}

/// Advance every sprite entity's animation cursor by `dt_s` WALL-CLOCK seconds (issue
/// #113 phase 2, item 3): for each entity with a `Sprite` and an `AnimationState`, add
/// `dt_s` to `time_s` and resolve the new position in the clip's frame list via
/// `animation.clipPosition`, writing it to `AnimationState.frame` (the renderer samples
/// sheet frame `clip.frames[frame]`). Cosmetic and hash-excluded: it reads real elapsed
/// time and writes only the unhashed `AnimationState` column, never sim state, so it can
/// never perturb `World.stateHash` (ADR 0031 §1). An entity whose sheet is unloaded or
/// whose clip name is absent (including an empty clip) holds frame 0. `dt_s <= 0` does
/// not advance time (it only accumulates forward). Owns nothing.
pub fn advance(world: *World, store: *const SheetStore, dt_s: f32) void {
    for (world.sprites.entities(), world.sprites.slice()) |idx, sprite| {
        const anim = world.animations.get(idx) orelse continue;
        if (dt_s > 0) anim.time_s += dt_s;
        const sheet = store.get(sprite.sheet) orelse {
            anim.frame = 0;
            continue;
        };
        const clip = findClip(sheet, sprite.clip) orelse {
            anim.frame = 0;
            continue;
        };
        const pos = animation.clipPosition(clip.frames.len, clip.fps, sprite.loop, anim.time_s);
        anim.frame = @intCast(pos);
    }
}

/// The clip named `name` in `sheet`, or null if none matches (an empty `name` never
/// matches, so a `Sprite` with no clip holds frame 0). Linear scan: clip counts are tiny.
pub fn findClip(sheet: *const msf.Sheet, name: []const u8) ?*const msf.Clip {
    for (sheet.clips) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

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

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

/// Build a `SheetStore` owning one decoded sheet under `ref` (encode→decode so the store
/// owns freeable slices, matching `loadForWorld`). Caller `deinit`s the returned store.
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

test "sprite: resolvePath maps a sheet ref to its generated artifact" {
    const gpa = testing.allocator;
    const p = try resolvePath(gpa, "games/pacman", "sprites/pac.msf");
    defer gpa.free(p);
    // The DERIVED artifact lives under `<recipe-dir>/generated/` (gitignored), not beside
    // the committed recipe. POSIX separators (the CI/native host).
    try testing.expectEqualStrings("games/pacman/sprites/generated/pac.msf", p);
}

test "sprite: loadForWorld reads generated sheets and skips missing ones" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a real generated artifact at <base>/sprites/generated/pac.msf.
    const px = [_]u8{ 7, 7, 7, 7 };
    const bytes = try msf.encode(gpa, .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "chomp", .fps = 8, .frames = &.{ 0, 0 } }},
    });
    defer gpa.free(bytes);
    try tmp.dir.createDirPath(io, "sprites/generated");
    try tmp.dir.writeFile(io, .{ .sub_path = "sprites/generated/pac.msf", .data = bytes });

    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setSprite(e, .{ .sheet = "sprites/pac.msf", .clip = "chomp" });
    // A second entity referencing the SAME sheet proves the load is de-duplicated.
    const e2 = try w.spawn();
    try w.setSprite(e2, .{ .sheet = "sprites/pac.msf", .clip = "chomp" });
    // A third references a sheet with NO file on disk — exercising the loader's
    // `error.FileNotFound` → warn-and-continue branch (a package whose assets have not
    // been generated must still load without erroring). It logs one warning line.
    const missing = try w.spawn();
    try w.setSprite(missing, .{ .sheet = "sprites/ghost.msf", .clip = "walk" });

    // pkg = "" ⇒ resolvePath yields "sprites/generated/<name>", relative to `base`.
    var store = try loadForWorld(gpa, io, tmp.dir, "", &w);
    defer store.deinit();

    // The on-disk sheet loads exactly once; the absent one is skipped (not an error,
    // absent from the store), so its entity holds frame 0.
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get("sprites/pac.msf") != null);
    try testing.expect(store.get("sprites/ghost.msf") == null);
    advance(&w, &store, 0.15); // 0.15 s at 8 fps → floor(1.2) = 1 → 1 % 2 = 1
    try testing.expectEqual(@as(u16, 1), w.getAnimationState(e).?.frame);
    try testing.expectEqual(@as(u16, 0), w.getAnimationState(missing).?.frame);
}

test "sprite: advance resolves the frame cursor from wall-clock time" {
    const gpa = testing.allocator;
    // A 1x1, 1-frame sheet with a 4-position clip at 10 fps (0.1 s/frame), looping.
    const px = [_]u8{ 1, 2, 3, 4 };
    var store = try storeWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "walk", .fps = 10, .frames = &.{ 0, 0, 0, 0 } }},
    });
    defer store.deinit();

    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setSprite(e, .{ .sheet = "s.msf", .clip = "walk", .loop = .loop });

    // 0.25 s at 10 fps → floor(2.5) = 2 → position 2 (mod 4).
    advance(&w, &store, 0.25);
    try testing.expectEqual(@as(u16, 2), w.getAnimationState(e).?.frame);
    // Another 0.20 s → 0.45 s → floor(4.5) = 4 → 4 % 4 = 0 (wrapped).
    advance(&w, &store, 0.20);
    try testing.expectEqual(@as(u16, 0), w.getAnimationState(e).?.frame);
}

test "sprite: an unknown clip or unloaded sheet holds frame 0" {
    const gpa = testing.allocator;
    const px = [_]u8{ 0, 0, 0, 0 };
    var store = try storeWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "walk", .fps = 10, .frames = &.{ 0, 0 } }},
    });
    defer store.deinit();

    var w = World.init(gpa);
    defer w.deinit();
    const missing_clip = try w.spawn();
    try w.setSprite(missing_clip, .{ .sheet = "s.msf", .clip = "nope" });
    const missing_sheet = try w.spawn();
    try w.setSprite(missing_sheet, .{ .sheet = "absent.msf", .clip = "walk" });

    advance(&w, &store, 5.0);
    try testing.expectEqual(@as(u16, 0), w.getAnimationState(missing_clip).?.frame);
    try testing.expectEqual(@as(u16, 0), w.getAnimationState(missing_sheet).?.frame);
}

test "sprite: advancing the cursor never perturbs the state hash (cosmetic, wall-clock)" {
    const gpa = testing.allocator;
    const px = [_]u8{ 9, 9, 9, 9 };
    var store = try storeWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "walk", .fps = 12, .frames = &.{ 0, 0, 0, 0 } }},
    });
    defer store.deinit();

    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } }); // hashed state
    try w.setSprite(e, .{ .sheet = "s.msf", .clip = "walk", .loop = .loop });

    const before = w.stateHash();
    advance(&w, &store, 1.0);
    // The cursor actually moved (the test is meaningful)…
    try testing.expect(w.getAnimationState(e).?.frame != 0 or w.getAnimationState(e).?.time_s != 0);
    // …yet the hash is byte-identical: animation is wall-clock-driven and excluded.
    try testing.expectEqual(before, w.stateHash());
}
