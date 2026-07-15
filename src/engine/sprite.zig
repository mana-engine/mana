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
//!
//! CPU atlas assembly (packing a `SheetStore`'s frames into one GPU-uploadable image) is
//! a third, separable concern that outgrew this file — it lives in the sibling
//! `sprite_atlas.zig` (issue #151) and is re-exported below (`Atlas`, `Region`,
//! `buildAtlas`, `merge`) so the public API (`sprite.Atlas`, `sprite.buildAtlas`, …) is
//! unchanged.
//!
//! Still over the ~500-line soft limit by design after that split: the remaining (a)
//! load and (b) animate-cursor halves are small and tightly coupled (`advance` reads the
//! very `SheetStore`/`msf.Clip` shapes `loadForScene`/`resolveFacing` define) and each
//! carries its own thorough behavior-named test suite (issue #113/#125/#128 regressions);
//! splitting further would either fragment two-line helpers across more files or force
//! another re-export layer for no real separation of concern (issue #151).

const std = @import("std");
const data = @import("data");
const animation = @import("animation.zig");
const World = @import("world.zig").World;
const prototype = @import("prototype.zig");

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
    /// The `Sprite.sheet` reference (e.g. `"sprites/pac.msf"`); borrowed from either a
    /// live world's `Sprite` component or a `prototype.Registry` entry's `.sprite.sheet`
    /// — whichever backing storage it came from, that storage must outlive the store.
    ref: []const u8,
    sheet: msf.Sheet,
};

/// Caches every distinct `.msf` sheet a scene can reference, decoded once at load and
/// keyed by the reference string. The store owns the decoded sheets; reference keys are
/// borrowed from whichever source supplied them — a live world's `Sprite` component OR a
/// `prototype.Registry` entry's `.sprite.sheet` (see `loadForScene`) — so every source
/// whose ref is held must outlive the store.
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

/// Load and decode every distinct sheet a scene could reference at load time into a
/// fresh `SheetStore` (issue #113 phase 2, item 2; phase 2b lifecycle fix): the union of
/// `world`'s live `Sprite` components AND every prototype in `prototypes` that declares
/// a `.sprite.sheet`. The prototype half matters because `Sim.enterScene` only QUEUES
/// `on_scene_enter` to fire on the first `sim.tick()` — a scene's Lua handler (e.g.
/// `games/pacman/rules.lua` spawning `pac` and the ghosts via `mana.spawn`) runs AFTER
/// this loader in `playLoop`, so `world.sprites` can still be EMPTY here even though the
/// scene is about to spawn sprited entities. The prototype registry is static content
/// known up front, so unioning it in guarantees those sheets are already decoded — and
/// in the atlas `buildAtlas` assembles from this store — before the entities that need
/// them exist. Each reference is resolved to its generated artifact (`resolvePath`)
/// relative to `base` (the runtime passes `Io.Dir.cwd()`), read via `io`, and decoded
/// with `data.msf`; distinct references (whether from a live entity or a prototype) are
/// loaded once. A referenced sheet that does not exist on disk is skipped with a warning
/// (its entities hold frame 0), so a package whose assets have not been generated still
/// runs — `mise run assets` produces them. Mirrors `scene.loadWorldFromFile`'s
/// `(gpa, io, base, …)` file-loading shape. Caller owns the store (`deinit`). Errors: file
/// read errors other than not-found, `msf.DecodeError`, `error.OutOfMemory`.
pub fn loadForScene(
    gpa: Allocator,
    io: Io,
    base: Io.Dir,
    pkg: []const u8,
    world: *World,
    prototypes: prototype.Registry,
) !SheetStore {
    var store: SheetStore = .{ .gpa = gpa };
    errdefer store.deinit();
    for (world.sprites.slice()) |sprite| try loadOne(&store, gpa, io, base, pkg, sprite.sheet);
    for (prototypes.prototypes) |proto| {
        const sp = proto.sprite orelse continue;
        try loadOne(&store, gpa, io, base, pkg, sp.sheet);
    }
    return store;
}

/// Decode `ref`'s generated artifact into `store`, unless already loaded or missing on
/// disk (warn-and-skip; see `loadForScene`). Shared by both the live-entity and
/// prototype passes so a sheet referenced by both is still loaded exactly once. Errors:
/// file read errors other than not-found, `msf.DecodeError`, `error.OutOfMemory`.
fn loadOne(store: *SheetStore, gpa: Allocator, io: Io, base: Io.Dir, pkg: []const u8, ref: []const u8) !void {
    if (store.get(ref) != null) return;
    const path = try resolvePath(gpa, pkg, ref);
    defer gpa.free(path);
    const read = base.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    const bytes = read catch |err| switch (err) {
        error.FileNotFound => {
            std.log.scoped(.sprite).warn("sheet not found: {s} (`mise run assets`)", .{path});
            return;
        },
        else => return err,
    };
    defer gpa.free(bytes);
    const sheet = try msf.decode(gpa, bytes);
    try store.entries.append(gpa, .{ .ref = ref, .sheet = sheet });
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
        // Latch the travel heading (ADR 0033 §3): retain the last NON-ZERO velocity so a
        // momentary stop at a grid intersection does not reset (and flicker) the facing.
        if (world.velocities.get(idx)) |vel| {
            if (vel.v.x != 0 or vel.v.y != 0) anim.heading = .{ .x = vel.v.x, .y = vel.v.y };
        }
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

/// A clip's resolved phase list for a facing, plus whether its UVs must be X-flipped.
pub const Resolved = struct {
    /// The phase list (frame indices into the sheet) to animate over — the `frame` cursor
    /// indexes this. Never empty unless the clip's base `frames` is empty.
    frames: []const u16,
    /// True ⇒ the renderer horizontally flips the sampled frame (the "absence is the
    /// signal" mirror, ADR 0033 §2): an authored facing is never mirrored, an inferred one
    /// (a horizontal facing derived from its authored opposite) always is.
    mirror_x: bool,
};

/// Select which phase list a clip plays for screen `facing`, and whether it is mirrored
/// (ADR 0033 §2). `facing` null (the entity has never moved / a non-directional clip) ⇒
/// the base `frames` list, no mirror. An authored facing is used as-authored. A missing
/// horizontal facing is inferred by X-flipping its authored opposite (declare-one =
/// mirror; declare-both = as-authored, no flip). A missing vertical facing — you cannot
/// flip "up" into "down" — falls back to the base `frames` list, no mirror. Pure; the
/// returned slice borrows `clip`.
pub fn resolveFacing(clip: *const msf.Clip, facing: ?msf.Facing) Resolved {
    const f = facing orelse return .{ .frames = clip.frames, .mirror_x = false };
    if (clip.facings[@intFromEnum(f)]) |list| return .{ .frames = list, .mirror_x = false };
    // The requested facing is absent: mirror a horizontal facing from its opposite.
    const opposite: ?msf.Facing = switch (f) {
        .left => .right,
        .right => .left,
        .up, .down => null, // vertical facings are never auto-derived
    };
    if (opposite) |o| {
        if (clip.facings[@intFromEnum(o)]) |list| return .{ .frames = list, .mirror_x = true };
    }
    return .{ .frames = clip.frames, .mirror_x = false };
}

/// CPU atlas assembly — split into `sprite_atlas.zig` (issue #151) and re-exported here
/// so the public API is unchanged. See that file for the full docs.
const sprite_atlas = @import("sprite_atlas.zig");
pub const Region = sprite_atlas.Region;
pub const Atlas = sprite_atlas.Atlas;
pub const buildAtlas = sprite_atlas.buildAtlas;
pub const merge = sprite_atlas.merge;

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

/// Build a `SheetStore` owning one decoded sheet under `ref` (encode→decode so the store
/// owns freeable slices, matching `loadForScene`). Caller `deinit`s the returned store.
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

test "sprite: loadForScene reads generated sheets and skips missing ones" {
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
    var store = try loadForScene(gpa, io, tmp.dir, "", &w, .{});
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

test "sprite: loadForScene includes a prototype-declared sheet even with an empty world" {
    // Reproduces issue #113's load-order bug: `Sim.enterScene` only QUEUES
    // `on_scene_enter` to fire on the first `sim.tick()`, and it is a scene's Lua
    // handler that spawns sprited entities (e.g. `mana.spawn("pac", …)` in
    // `games/pacman/rules.lua`) — so at load time (before that first tick)
    // `world.sprites` is EMPTY even though the scene's prototype registry already
    // knows `pac` needs `sprites/pac.msf`. The loader must pull that sheet in from
    // `prototypes` alone, or the atlas built from an empty store stays zero-sized and
    // the sprite never renders (a flat `Appearance` quad shows instead).
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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
    // No entities spawned yet — `world.sprites` is empty, exactly like at load time.
    try testing.expectEqual(@as(usize, 0), w.sprites.slice().len);

    const protos = [_]prototype.Prototype{
        .{ .name = "pac", .sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp" } },
        .{ .name = "wall" }, // a prototype with no sprite at all must not error
    };
    const reg: prototype.Registry = .{ .prototypes = &protos };

    var store = try loadForScene(gpa, io, tmp.dir, "", &w, reg);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get("sprites/pac.msf") != null);
}

test "sprite: loadForScene loads a sheet shared by a live entity and a prototype exactly once" {
    // The same `ref` appears in BOTH sources (a spawned entity AND a prototype) — the
    // common case for pacman, where the scene has already spawned pac by the time a
    // later reload runs and the `pac` prototype still declares the same sheet. `loadOne`'s
    // `store.get(ref)` guard must de-duplicate across the two passes, not decode twice.
    const gpa = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    const protos = [_]prototype.Prototype{
        .{ .name = "pac", .sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp" } },
    };
    const reg: prototype.Registry = .{ .prototypes = &protos };

    var store = try loadForScene(gpa, io, tmp.dir, "", &w, reg);
    defer store.deinit();

    // One shared ref across both sources ⇒ one decoded entry, not two.
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.get("sprites/pac.msf") != null);
}

test "sprite: resolveFacing picks the authored list, infers a mirror, or falls back" {
    // right + down authored; left and up absent.
    const clip: msf.Clip = .{
        .name = "chomp",
        .fps = 12,
        .frames = &.{ 0, 1 }, // base
        .facings = .{ null, &.{ 8, 9 }, null, &.{ 0, 1 } }, // up, down, left, right
    };
    // An authored facing is used as-authored, no mirror.
    {
        const r = resolveFacing(&clip, .right);
        try testing.expectEqualSlices(u16, &.{ 0, 1 }, r.frames);
        try testing.expect(!r.mirror_x);
    }
    {
        const r = resolveFacing(&clip, .down);
        try testing.expectEqualSlices(u16, &.{ 8, 9 }, r.frames);
        try testing.expect(!r.mirror_x);
    }
    // A missing horizontal facing (left) infers the mirror of its opposite (right).
    {
        const r = resolveFacing(&clip, .left);
        try testing.expectEqualSlices(u16, &.{ 0, 1 }, r.frames);
        try testing.expect(r.mirror_x);
    }
    // A missing vertical facing (up) is never mirrored — it falls back to base, no flip.
    {
        const r = resolveFacing(&clip, .up);
        try testing.expectEqualSlices(u16, &.{ 0, 1 }, r.frames);
        try testing.expect(!r.mirror_x);
    }
    // No facing (never moved / non-directional) ⇒ base, no flip.
    {
        const r = resolveFacing(&clip, null);
        try testing.expectEqualSlices(u16, &.{ 0, 1 }, r.frames);
        try testing.expect(!r.mirror_x);
    }
}

test "sprite: resolveFacing does NOT mirror when both horizontal facings are authored" {
    // Both left and right authored (an asymmetric character): each is used as-authored.
    const clip: msf.Clip = .{
        .name = "walk",
        .fps = 8,
        .frames = &.{0},
        .facings = .{ null, null, &.{ 4, 5 }, &.{ 0, 1 } }, // left AND right present
    };
    const left = resolveFacing(&clip, .left);
    try testing.expectEqualSlices(u16, &.{ 4, 5 }, left.frames);
    try testing.expect(!left.mirror_x); // voluntary declaration overrides inference
    const right = resolveFacing(&clip, .right);
    try testing.expectEqualSlices(u16, &.{ 0, 1 }, right.frames);
    try testing.expect(!right.mirror_x);
}

test "sprite: advance latches the last non-zero heading across a momentary stop" {
    const gpa = testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4 };
    var store = try storeWith(gpa, "s.msf", .{
        .width = 1,
        .height = 1,
        .frames = &.{&px},
        .clips = &.{.{ .name = "walk", .fps = 10, .frames = &.{0} }},
    });
    defer store.deinit();

    var w = World.init(gpa);
    defer w.deinit();
    const e = try w.spawn();
    try w.setSprite(e, .{ .sheet = "s.msf", .clip = "walk" });

    // Moving +x latches heading (+1, 0).
    try w.setVelocity(e, .{ .v = .{ .x = 1, .y = 0, .z = 0 } });
    advance(&w, &store, 0.05);
    try testing.expectEqual(@as(f32, 1), w.getAnimationState(e).?.heading.x);
    try testing.expectEqual(@as(f32, 0), w.getAnimationState(e).?.heading.y);

    // Velocity drops to zero (an intersection): the latched heading is RETAINED, not reset.
    try w.setVelocity(e, .{ .v = .{ .x = 0, .y = 0, .z = 0 } });
    advance(&w, &store, 0.05);
    try testing.expectEqual(@as(f32, 1), w.getAnimationState(e).?.heading.x);

    // A new non-zero velocity updates the latch.
    try w.setVelocity(e, .{ .v = .{ .x = 0, .y = -2, .z = 0 } });
    advance(&w, &store, 0.05);
    try testing.expectEqual(@as(f32, 0), w.getAnimationState(e).?.heading.x);
    try testing.expectEqual(@as(f32, -2), w.getAnimationState(e).?.heading.y);
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
