//! Entity prototypes (ADR 0016): named, `EntityDef`-shaped component templates a
//! package declares in ZON and `mana.spawn(name, x, y, z)` instantiates. The engine
//! holds a `Registry` (name → template) and resolves a spawn against it through the
//! host seam (ADR 0015); it knows the *format*, never a specific prototype
//! (invariant #6 — genre lives in content, not `src/`). A prototype is data, not
//! script (CLAUDE.md: prefer data over Lua).

const std = @import("std");
const core = @import("core");
const data = @import("data");
const gpu = @import("gpu");
const components = @import("components.zig");
const scene = @import("scene.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A prototype is exactly a scene entity definition (ADR 0004 §6): a `name` plus one
/// optional field per built-in component. Reused wholesale so there is one
/// entity-template shape across scenes and prototypes (ADR 0016).
pub const Prototype = scene.EntityDef;

/// A parsed prototype file (ADR 0016): a package ZON resource declaring the named
/// templates `mana.spawn` may instantiate — `.{ .prototypes = .{ <Prototype>… } }`.
/// Owns its heap allocations (names, the slice); free with `free`. A `Registry`
/// borrows `prototypes`, so the `File` must outlive any `Registry` built from it.
pub const File = struct {
    prototypes: []const Prototype,
};

/// Parse a prototype file from NUL-terminated ZON `source` (same parser as scenes).
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!File {
    return data.parse(File, gpa, source);
}

/// Free a `File` returned by `parse`.
pub fn free(gpa: Allocator, file: File) void {
    data.free(gpa, file);
}

/// A package's merged prototype set (ADR 0038 §2): every `<pkg>/prototypes/*.zon`
/// file, parsed and concatenated into one flat template list. Owns the parsed files
/// and the merged slice; a `Registry` borrows `.prototypes`, so the `Set` must
/// outlive any registry (and any `Sim`) built from it. Free with `deinit`.
pub const Set = struct {
    gpa: Allocator,
    /// The parsed source files, kept alive because `prototypes` borrows their strings.
    files: []File,
    /// The merged templates, in load order (byte-lexicographic file path, then
    /// declared order within a file). Empty when the package declares no prototypes.
    prototypes: []const Prototype,

    /// Free the merged slice and every parsed file. Invalidates any `Registry`
    /// borrowing `.prototypes`; tear those (and their `Sim`) down first.
    pub fn deinit(self: *Set) void {
        self.gpa.free(self.prototypes);
        for (self.files) |f| free(self.gpa, f);
        self.gpa.free(self.files);
        self.* = undefined;
    }
};

/// Glob, parse, and merge every `*.zon` file directly under `<pkg>/prototypes/`
/// (ADR 0038 §2). `base` is the filesystem root the package path is relative to
/// (`Io.Dir.cwd()` for the runner, a temp dir in tests). Files are loaded in
/// **byte-lexicographic order of their name** — a total, OS-independent order the
/// loader imposes explicitly so registration order (and thus the state hash) is
/// stable regardless of the directory's native iteration order. Each file is the
/// unchanged `.{ .prototypes = .{ … } }` shape; their lists are concatenated.
///
/// A **duplicate prototype `name`** across files is `error.DuplicatePrototypeName`
/// (ADR 0038 §2: a hard load error, never last-wins — silent shadowing would make
/// load order semantic). A missing `prototypes/` directory is **not** an error: it
/// yields an empty set (a package may declare no prototypes). Caller owns the
/// result; `deinit` it after any `Sim`/`Registry` borrowing it is gone. Errors:
/// directory/file I/O, `error.ParseZon`, `error.OutOfMemory`, and the duplicate case.
pub fn loadDir(gpa: Allocator, io: Io, base: Io.Dir, pkg: []const u8) !Set {
    const sub = try std.fs.path.join(gpa, &.{ pkg, "prototypes" });
    defer gpa.free(sub);
    var dir = base.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .gpa = gpa, .files = &.{}, .prototypes = &.{} },
        else => return err,
    };
    defer dir.close(io);

    // Collect the `.zon` file names (duped — an entry's name is valid only until the
    // next iteration), then sort byte-lexicographically for a deterministic load order.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanName);

    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |f| free(gpa, f);
        files.deinit(gpa);
    }
    for (names.items) |name| {
        const src = try dir.readFileAllocOptions(io, name, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(src);
        try files.append(gpa, try parse(gpa, src));
    }

    // Concatenate, rejecting a name that already appeared in an earlier file.
    var total: usize = 0;
    for (files.items) |f| total += f.prototypes.len;
    const merged = try gpa.alloc(Prototype, total);
    errdefer gpa.free(merged);
    var n: usize = 0;
    for (files.items) |f| {
        for (f.prototypes) |p| {
            for (merged[0..n]) |seen| {
                if (std.mem.eql(u8, seen.name, p.name)) return error.DuplicatePrototypeName;
            }
            merged[n] = p;
            n += 1;
        }
    }
    return .{ .gpa = gpa, .files = try files.toOwnedSlice(gpa), .prototypes = merged };
}

/// Byte-lexicographic order over file names (the deterministic prototype load order).
fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The component set to attach when `proto` is spawned at `pos`: the template's
/// components with `Transform.pos` set to the spawn point — `mana.spawn`'s position
/// overrides the template's (ADR 0016). A prototype without a `transform` gets one
/// at the spawn point.
pub fn bundleAt(proto: Prototype, pos: core.Vec3) components.Bundle {
    var transform = proto.transform orelse components.Transform{ .pos = pos };
    transform.pos = pos; // spawn position wins over any template position
    return .{
        .transform = transform,
        .velocity = proto.velocity,
        .health = proto.health,
        .collider = proto.collider, // collider (ADR 0025) carries through as-is
        .data = proto.data, // named data components (ADR 0024) carry through as-is
        .nav_agent = proto.nav_agent, // nav agent (ADR 0027) carries through as-is
        .appearance = proto.appearance, // appearance (ADR 0030) carries through as-is
        .sprite = proto.sprite, // sprite ref (ADR 0031) carries through as-is
        .tint_cue = proto.tint_cue, // tint + blink cue (issue #128) carries through as-is
    };
}

/// Name → prototype lookup `mana.spawn` resolves against. A thin index over a slice
/// of prototypes owned elsewhere (the runner's parsed ZON, or a test's fixed array);
/// the registry itself allocates nothing. Linear scan: prototype counts are small
/// and lookup order does not affect determinism (spawns flow through the command
/// buffer regardless).
pub const Registry = struct {
    prototypes: []const Prototype = &.{},

    /// The prototype named `name`, or null if none matches (a content bug the caller
    /// reports; never a crash).
    pub fn lookup(self: Registry, name: []const u8) ?Prototype {
        for (self.prototypes) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

const testing = std.testing;

test "prototype: bundleAt overrides the template position with the spawn point" {
    const proto: Prototype = .{
        .name = "crate",
        .transform = .{ .pos = .{ .x = 99, .y = 99, .z = 99 } }, // template pos ignored
        .health = .{ .current = 5, .max = 5 },
    };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 2, .z = 3 });
    try testing.expect(bundle.transform.?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(f32, 5), bundle.health.?.current); // other components carry through
    try testing.expect(bundle.velocity == null); // absent template component stays absent
}

test "prototype: bundleAt carries named data components through to the bundle" {
    const vals = [_]components.NamedValue{ .{ .name = "hp", .value = 3 }, .{ .name = "score", .value = 0 } };
    const proto: Prototype = .{ .name = "orb", .data = &vals };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 1, .z = 0 });
    try testing.expectEqual(@as(usize, 2), bundle.data.len);
    try testing.expectEqualStrings("hp", bundle.data[0].name);
    try testing.expectEqual(@as(f64, 3), bundle.data[0].value);
}

test "prototype: bundleAt carries a collider through to the bundle" {
    const proto: Prototype = .{
        .name = "turret",
        .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true },
    };
    const bundle = bundleAt(proto, .{ .x = 2, .y = 3, .z = 0 });
    try testing.expectEqual(@as(f32, 0.5), bundle.collider.?.shape.circle.radius);
    try testing.expect(bundle.collider.?.is_static);
}

test "prototype: bundleAt gives a transformless prototype a transform at the spawn point" {
    const proto: Prototype = .{ .name = "spark", .velocity = .{ .v = .{ .x = 1, .y = 0, .z = 0 } } };
    const bundle = bundleAt(proto, .{ .x = 4, .y = 5, .z = 6 });
    try testing.expect(bundle.transform.?.pos.approxEql(.{ .x = 4, .y = 5, .z = 6 }, 1e-6));
    try testing.expect(bundle.velocity.?.v.approxEql(.{ .x = 1, .y = 0, .z = 0 }, 1e-6));
}

test "prototype: bundleAt carries an appearance through to the bundle" {
    const proto: Prototype = .{
        .name = "pac",
        .appearance = .{ .color = .{ 1, 0.9, 0.2 }, .size = 0.7 },
    };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 1, .z = 0 });
    try testing.expect(std.mem.eql(f32, &.{ 1, 0.9, 0.2 }, &bundle.appearance.?.color));
    try testing.expectEqual(@as(f32, 0.7), bundle.appearance.?.size);
}

test "prototype: bundleAt carries an appearance's shape through to the bundle" {
    const proto: Prototype = .{
        .name = "pac",
        .appearance = .{ .color = .{ 1, 0.9, 0.2 }, .shape = .circle },
    };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 1, .z = 0 });
    try testing.expectEqual(gpu.Shape.circle, bundle.appearance.?.shape);
}

test "prototype: bundleAt carries a sprite reference through to the bundle" {
    const proto: Prototype = .{
        .name = "pac",
        .sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp", .loop = .ping_pong },
    };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 1, .z = 0 });
    try testing.expectEqualStrings("sprites/pac.msf", bundle.sprite.?.sheet);
    try testing.expectEqualStrings("chomp", bundle.sprite.?.clip);
    try testing.expectEqual(components.LoopMode.ping_pong, bundle.sprite.?.loop);
}

test "prototype registry: lookup finds a named prototype and misses cleanly" {
    const protos = [_]Prototype{
        .{ .name = "head", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } },
        .{ .name = "food", .health = .{ .current = 1, .max = 1 } },
    };
    const reg: Registry = .{ .prototypes = &protos };
    try testing.expectEqualStrings("food", reg.lookup("food").?.name);
    try testing.expect(reg.lookup("missing") == null);
    try testing.expect((Registry{}).lookup("head") == null); // empty registry: always a miss
}

test "prototype file: parse round-trips a package prototype list into a registry" {
    const src =
        \\.{
        \\    .prototypes = .{
        \\        .{ .name = "segment", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } },
        \\        .{ .name = "food", .health = .{ .current = 1, .max = 1 } },
        \\    },
        \\}
    ;
    const file = try parse(testing.allocator, src);
    defer free(testing.allocator, file);

    try testing.expectEqual(@as(usize, 2), file.prototypes.len);
    const reg: Registry = .{ .prototypes = file.prototypes };
    try testing.expectEqualStrings("segment", reg.lookup("segment").?.name);
    try testing.expectEqual(@as(f32, 1), reg.lookup("food").?.health.?.current);
}

test "prototype loadDir: globs and merges files in byte-lexicographic name order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try tmp.dir.createDirPath(io, "pkg/prototypes");
    // Written out of order; the loader must sort by name (ghosts.zon before pac.zon).
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/pac.zon", .data = ".{ .prototypes = .{ .{ .name = \"pac\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/ghosts.zon", .data = ".{ .prototypes = .{ .{ .name = \"blinky\" }, .{ .name = \"clyde\" } } }" });

    var set = try loadDir(gpa, io, tmp.dir, "pkg");
    defer set.deinit();

    try testing.expectEqual(@as(usize, 3), set.prototypes.len);
    // ghosts.zon sorts first, then in-file order; pac.zon last.
    try testing.expectEqualStrings("blinky", set.prototypes[0].name);
    try testing.expectEqualStrings("clyde", set.prototypes[1].name);
    try testing.expectEqualStrings("pac", set.prototypes[2].name);

    const reg: Registry = .{ .prototypes = set.prototypes };
    try testing.expectEqualStrings("pac", reg.lookup("pac").?.name); // lookup is name-keyed
}

test "prototype loadDir: a missing prototypes directory is an empty set, not an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try tmp.dir.createDirPath(io, "pkg"); // pkg exists, but no prototypes/ under it
    var set = try loadDir(gpa, io, tmp.dir, "pkg");
    defer set.deinit();
    try testing.expectEqual(@as(usize, 0), set.prototypes.len);
}

test "prototype loadDir: a duplicate prototype name across files is a hard error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try tmp.dir.createDirPath(io, "pkg/prototypes");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/a.zon", .data = ".{ .prototypes = .{ .{ .name = \"dup\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/b.zon", .data = ".{ .prototypes = .{ .{ .name = \"dup\" } } }" });

    try testing.expectError(error.DuplicatePrototypeName, loadDir(gpa, io, tmp.dir, "pkg"));
}

test "prototype loadDir: non-.zon files are ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try tmp.dir.createDirPath(io, "pkg/prototypes");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/e.zon", .data = ".{ .prototypes = .{ .{ .name = \"e\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/prototypes/README.md", .data = "not zon" });

    var set = try loadDir(gpa, io, tmp.dir, "pkg");
    defer set.deinit();
    try testing.expectEqual(@as(usize, 1), set.prototypes.len);
    try testing.expectEqualStrings("e", set.prototypes[0].name);
}

test "prototype file: parse round-trips a collider-bearing prototype" {
    const src =
        \\.{
        \\    .prototypes = .{
        \\        .{ .name = "food", .collider = .{ .shape = .{ .circle = .{ .radius = 0.3 } }, .layers = .{ .layer = 4, .mask = 1 } } },
        \\    },
        \\}
    ;
    const file = try parse(testing.allocator, src);
    defer free(testing.allocator, file);

    const reg: Registry = .{ .prototypes = file.prototypes };
    const food = reg.lookup("food").?;
    try testing.expectEqual(@as(f32, 0.3), food.collider.?.shape.circle.radius);
    try testing.expectEqual(@as(u32, 4), food.collider.?.layers.layer);
    try testing.expect(!food.collider.?.is_static);
}
