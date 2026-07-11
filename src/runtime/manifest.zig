//! The `game.zon` manifest format. `runtime` knows this format but never any
//! specific game — a game is content passed in at runtime. Parsing is pure
//! (source in, data out); the runner does the file I/O. Nothing here references
//! `games/**`.

const std = @import("std");
const data = @import("data");

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
        \\    .scenes = .{ "scenes/hello.zon" },
        \\}
    ;
    const m = try parse(testing.allocator, src);
    defer free(testing.allocator, m);
    try testing.expectEqualStrings("sandbox", m.name);
    try testing.expectEqualStrings("scenes/hello.zon", m.entry_scene);
    try testing.expectEqual(@as(usize, 1), m.scenes.len);
    try testing.expect(m.native_module == null);
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
