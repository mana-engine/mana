//! The `game.zon` manifest format. `runtime` knows this format but never any
//! specific game — a game is content passed in at runtime. Parsing is pure
//! (source in, data out); the runner does the file I/O. Nothing here references
//! `games/**`.

const std = @import("std");
const data = @import("data");
const engine = @import("engine");

const Allocator = std.mem.Allocator;

/// Optional declaration of a game's native module: a versioned C-ABI dylib
/// (init/tick/shutdown + engine API pointer). Opt-in and rare.
pub const NativeModule = struct {
    /// Path to the dylib, relative to the game package root.
    path: []const u8,
    /// C-ABI version the module was built against; the runner refuses a mismatch.
    abi_version: u32,
};

/// A parsed `game.zon`. Paths are relative to the game package root.
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    entry_scene: []const u8,
    scenes: []const []const u8,
    native_module: ?NativeModule = null,
    /// Scripting API version this package requires (ADR 0003 gate). 0 = none.
    /// The runner refuses a version higher than the build provides.
    script_api: u32 = 0,
    /// Camera projection the package is framed through (ADR 0014). Defaults to
    /// top-down orthographic; isometric content declares `.isometric` explicitly.
    /// The engine has no hardcoded camera — the projection comes from package data.
    projection: engine.render.Projection = .{ .orthographic = .{} },
};

/// Parse a manifest from NUL-terminated ZON `source`. Unknown fields are ignored
/// so older runners tolerate newer manifests. The result owns heap allocations;
/// free with `free`.
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!Manifest {
    return data.parseLenient(Manifest, gpa, source);
}

/// Free a `Manifest` returned by `parse`.
pub fn free(gpa: Allocator, manifest: Manifest) void {
    data.free(gpa, manifest);
}

/// The package-relative files whose changes should trigger a hot reload: the
/// manifest itself plus every scene it references. Returned paths borrow from
/// `manifest`; the slice is owned by `gpa` (free it, not the elements).
pub fn watchPaths(gpa: Allocator, manifest: Manifest) Allocator.Error![]const []const u8 {
    const paths = try gpa.alloc([]const u8, manifest.scenes.len + 1);
    paths[0] = "game.zon";
    for (manifest.scenes, paths[1..]) |scene, *dst| dst.* = scene;
    return paths;
}

const testing = std.testing;

test "manifest: parse a minimal game.zon" {
    const src =
        \\.{
        \\    .name = "sandbox",
        \\    .version = "0.0.1",
        \\    .entry_scene = "scenes/hello.zon",
        \\    .scenes = .{ "scenes/hello.zon" },
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("sandbox", m.name);
    try testing.expectEqualStrings("scenes/hello.zon", m.entry_scene);
    try testing.expectEqual(@as(usize, 1), m.scenes.len);
    try testing.expect(m.native_module == null);
    try testing.expectEqual(@as(u32, 0), m.script_api); // defaults to none
}

test "manifest: projection defaults to orthographic, iso is declared explicitly" {
    const default_src =
        \\.{
        \\    .name = "grid",
        \\    .version = "0.1.0",
        \\    .entry_scene = "s.zon",
        \\    .scenes = .{ "s.zon" },
        \\}
    ;
    const d = try parse(testing.allocator, default_src);
    defer free(testing.allocator, d);
    try testing.expect(d.projection == .orthographic); // no field → top-down default

    const iso_src =
        \\.{
        \\    .name = "iso",
        \\    .version = "0.1.0",
        \\    .entry_scene = "s.zon",
        \\    .scenes = .{ "s.zon" },
        \\    .projection = .{ .isometric = .{ .half_w = 30, .half_h = 15, .z_height = 20 } },
        \\}
    ;
    const m = try parse(testing.allocator, iso_src);
    defer free(testing.allocator, m);
    try testing.expect(m.projection == .isometric);
    try testing.expectEqual(@as(f32, 30), m.projection.isometric.half_w);
}

test "manifest: parse an optional native module" {
    const src =
        \\.{
        \\    .name = "hot",
        \\    .version = "1.0.0",
        \\    .entry_scene = "s.zon",
        \\    .scenes = .{ "s.zon" },
        \\    .native_module = .{ .path = "libhot.so", .abi_version = 1 },
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expect(m.native_module != null);
    try testing.expectEqual(@as(u32, 1), m.native_module.?.abi_version);
}

test "manifest: watchPaths lists the manifest plus every referenced scene" {
    const src =
        \\.{
        \\    .name = "m",
        \\    .version = "1",
        \\    .entry_scene = "scenes/a.zon",
        \\    .scenes = .{ "scenes/a.zon", "scenes/b.zon" },
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);

    const paths = try watchPaths(testing.allocator, m);
    defer testing.allocator.free(paths);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("game.zon", paths[0]);
    try testing.expectEqualStrings("scenes/a.zon", paths[1]);
    try testing.expectEqualStrings("scenes/b.zon", paths[2]);
}

test "manifest: unknown fields are tolerated" {
    const src =
        \\.{
        \\    .name = "future",
        \\    .version = "9.9.9",
        \\    .entry_scene = "s.zon",
        \\    .scenes = .{ "s.zon" },
        \\    .some_new_field = 123,
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("future", m.name);
}
