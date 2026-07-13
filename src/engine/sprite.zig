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
        const bytes = base.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.scoped(.sprite).warn("sheet not found: {s} (run `mise run assets`); entities hold frame 0", .{path});
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
fn findClip(sheet: *const msf.Sheet, name: []const u8) ?*const msf.Clip {
    for (sheet.clips) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
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

    // pkg = "" ⇒ resolvePath yields "sprites/generated/<name>", relative to `base`.
    var store = try loadForWorld(gpa, io, tmp.dir, "", &w);
    defer store.deinit();

    // The one referenced sheet is loaded exactly once and drives the cursor. (A
    // reference to an absent sheet is skipped — see the "unloaded sheet holds frame 0"
    // case, which exercises that path without touching the filesystem.)
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get("sprites/pac.msf") != null);
    advance(&w, &store, 0.15); // 0.15 s at 8 fps → floor(1.2) = 1 → 1 % 2 = 1
    try testing.expectEqual(@as(u16, 1), w.getAnimationState(e).?.frame);
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
