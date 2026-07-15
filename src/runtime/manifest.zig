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
///
/// Convention over configuration for bulk content (ADR 0038 §4): the manifest names
/// only identity, the one start scene, the script *entry*, and cross-cutting settings
/// — it does **not** enumerate the package's scenes or prototype files. Those are
/// discovered by globbing the conventional kind-directories (`scenes/`, `prototypes/`,
/// `scripts/`), so adding content needs no manifest edit (the file's presence is the
/// declaration — invariant #1, files-are-truth).
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    /// The one distinguished start scene, package-relative (e.g. `scenes/maze.zon`).
    /// Named because it is not discoverable — a package has exactly one entry scene.
    entry_scene: []const u8,
    native_module: ?NativeModule = null,
    /// Scripting API version this package requires (ADR 0003 gate). 0 = none.
    /// The runner refuses a version higher than the build provides.
    script_api: u32 = 0,
    /// Camera projection the package is framed through (ADR 0014). Defaults to
    /// top-down orthographic; isometric content declares `.isometric` explicitly.
    /// The engine has no hardcoded camera — the projection comes from package data.
    projection: engine.render.Projection = .{ .orthographic = .{} },
    /// Optional Lua handler script *entry* (ADR 0003 §1; issue #51; ADR 0038 §1): a
    /// package-relative `.lua` path (conventionally `scripts/rules.lua`) loaded as the
    /// Sim's single event-handler table. Sibling modules under `scripts/` are composed
    /// by the entry, not listed here. Absent ⇒ the package has no script. Watched for
    /// hot reload. A package that actually needs
    /// scripting should also set `script_api`, so a build without `-Denable-lua` is
    /// refused rather than silently running scriptless.
    script: ?[]const u8 = null,
    /// Optional data-driven HUD screen (ADR 0034; issue #133): a package-relative ZON
    /// path parsed as a `ui.Screen` and composited (display-only) over the game frame in
    /// `--play` and `--render-play-frame`. Absent ⇒ no HUD (genre-neutral: the engine
    /// draws whatever the package declares). Watched for hot reload.
    hud: ?[]const u8 = null,
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

const testing = std.testing;

test "manifest: parse a minimal game.zon" {
    const src =
        \\.{
        \\    .name = "sandbox",
        \\    .version = "0.0.1",
        \\    .entry_scene = "scenes/hello.zon",
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("sandbox", m.name);
    try testing.expectEqualStrings("scenes/hello.zon", m.entry_scene);
    try testing.expect(m.native_module == null);
    try testing.expectEqual(@as(u32, 0), m.script_api); // defaults to none
    try testing.expect(m.script == null);
    try testing.expect(m.hud == null);
}

test "manifest: projection defaults to orthographic, iso is declared explicitly" {
    const default_src =
        \\.{
        \\    .name = "grid",
        \\    .version = "0.1.0",
        \\    .entry_scene = "s.zon",
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
        \\    .native_module = .{ .path = "libhot.so", .abi_version = 1 },
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expect(m.native_module != null);
    try testing.expectEqual(@as(u32, 1), m.native_module.?.abi_version);
}

test "manifest: script entry and script_api parse" {
    const src =
        \\.{
        \\    .name = "s",
        \\    .version = "1",
        \\    .entry_scene = "scenes/a.zon",
        \\    .script = "scripts/rules.lua",
        \\    .script_api = 1,
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("scripts/rules.lua", m.script.?);
    try testing.expectEqual(@as(u32, 1), m.script_api);
}

test "manifest: hud field parses; defaults to null" {
    const with_hud =
        \\.{
        \\    .name = "h",
        \\    .version = "1",
        \\    .entry_scene = "scenes/a.zon",
        \\    .hud = "hud.zon",
        \\}
    ;
    const m = try parse(testing.allocator, with_hud);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("hud.zon", m.hud.?);

    const no_hud =
        \\.{
        \\    .name = "h",
        \\    .version = "1",
        \\    .entry_scene = "s.zon",
        \\}
    ;
    const d = try parse(testing.allocator, no_hud);
    defer free(testing.allocator, d);
    try testing.expect(d.hud == null);
}

test "manifest: bulk-content and unknown fields are tolerated (globbed, not enumerated)" {
    // A pre-ADR-0038 manifest still parses: the retired `scenes`/`prototypes` bulk
    // fields (and any future field) are ignored by `parseLenient`, so an older-format
    // package loads under the new globbing loader without a manifest edit.
    const src =
        \\.{
        \\    .name = "future",
        \\    .version = "9.9.9",
        \\    .entry_scene = "s.zon",
        \\    .scenes = .{ "s.zon" },
        \\    .prototypes = "prototypes.zon",
        \\    .some_new_field = 123,
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("future", m.name);
    try testing.expectEqualStrings("s.zon", m.entry_scene);
}
