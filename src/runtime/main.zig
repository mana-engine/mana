//! runtime — the `mana` runner executable. Loads a game content package by path,
//! parses its `game.zon` manifest and entry scene, and either runs a fixed number
//! of deterministic steps and prints a state hash (default), or watches the whole
//! package — the manifest plus every referenced scene — and hot-reloads on change
//! (`--watch`, ADR 0005). It knows the manifest *format* but never any specific
//! game; nothing here references `games/**`.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const engine = @import("engine");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Manifest = manifest_mod.Manifest;

/// Highest scripting API version this build provides (ADR 0003 gate). 0 = no
/// scripting compiled in yet; a package requesting more is refused.
const provided_script_api: u32 = 0;
/// Number of fixed steps a one-shot headless run advances before reporting.
const tick_steps: u32 = 60;
/// Poll cadence for `--watch`, in milliseconds.
const watch_poll_ms: i64 = 100;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    // First non-flag argument is the package dir; `--watch` enables hot reload.
    const args = try init.minimal.args.toSlice(arena);
    var pkg_path: ?[]const u8 = null;
    var watch = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--watch")) watch = true else if (pkg_path == null) pkg_path = a;
    }
    const pkg = pkg_path orelse {
        try out.writeAll("usage: mana <game-package-dir> [--watch]\n");
        try out.flush();
        return;
    };

    if (watch) return runWatch(out, io, gpa, pkg);
    return runOnce(out, io, gpa, pkg);
}

/// Load `<pkg>/game.zon`. Caller owns the result; free with `manifest_mod.free`.
fn loadManifest(io: Io, gpa: Allocator, pkg: []const u8) !Manifest {
    const path = try std.fs.path.join(gpa, &.{ pkg, "game.zon" });
    defer gpa.free(path);
    const src = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    return manifest_mod.parse(gpa, src);
}

/// Refuse a package that needs a newer scripting API than this build provides.
fn checkScriptApi(out: *Io.Writer, manifest: Manifest) !void {
    if (manifest.script_api > provided_script_api) {
        try out.print(
            "mana: '{s}' requires scripting API v{d}, but this build provides v{d}\n",
            .{ manifest.name, manifest.script_api, provided_script_api },
        );
        try out.flush();
        return error.UnsupportedScriptApi;
    }
}

/// One-shot: load, advance `tick_steps`, print the deterministic state hash.
fn runOnce(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    var world = try engine.scene.loadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path);
    defer world.deinit();
    for (0..tick_steps) |_| engine.systems.movement(&world, core.time.default_dt);

    try out.print(
        "mana: ran '{s}' v{s} — {d} entities, {d} ticks, state hash 0x{x:0>16}\n",
        .{ manifest.name, manifest.version, world.count(), tick_steps, world.stateHash() },
    );
    try out.flush();
}

/// Register the package's watch set — its manifest and every referenced scene — as
/// paths relative to cwd, replacing any previous set.
fn syncWatchSet(watcher: *data.Watcher, io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !void {
    watcher.clear();
    const rels = try manifest_mod.watchPaths(gpa, manifest);
    defer gpa.free(rels);
    for (rels) |rel| {
        const joined = try std.fs.path.join(gpa, &.{ pkg, rel });
        defer gpa.free(joined);
        try watcher.add(io, joined);
    }
}

/// Watch mode: tick, poll the whole package, hot-reload on change (last-good-wins).
fn runWatch(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8) !void {
    var manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    var scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);

    var watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer watcher.deinit();
    try syncWatchSet(&watcher, io, gpa, pkg, manifest);

    var world = try engine.scene.loadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path);
    defer world.deinit();

    try out.print(
        "mana: watching '{s}' — {d} files (manifest + scenes); Ctrl-C to stop\n",
        .{ manifest.name, watcher.watchedCount() },
    );
    try out.flush();

    while (true) {
        engine.systems.movement(&world, core.time.default_dt);
        if (watcher.poll(io)) {
            try onChange(out, io, gpa, pkg, &manifest, &scene_path, &watcher, &world);
        }
        try Io.sleep(io, Io.Duration.fromMilliseconds(watch_poll_ms), .awake);
    }
}

/// Handle a detected change: re-parse the manifest and re-sync the watch set (both
/// last-good-wins), then rebuild the world from the current entry scene.
fn onChange(
    out: *Io.Writer,
    io: Io,
    gpa: Allocator,
    pkg: []const u8,
    manifest: *Manifest,
    scene_path: *[]u8,
    watcher: *data.Watcher,
    world: *engine.World,
) !void {
    // Re-parse the manifest; on success re-point the entry scene and re-sync the
    // watch set (the scene list may have changed). On failure keep the last good.
    if (loadManifest(io, gpa, pkg)) |next| {
        if (next.script_api > provided_script_api) {
            manifest_mod.free(gpa, next);
            try out.print("mana: new manifest needs scripting API v{d} — keeping last good\n", .{next.script_api});
        } else {
            manifest_mod.free(gpa, manifest.*);
            manifest.* = next;
            gpa.free(scene_path.*);
            scene_path.* = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
            try syncWatchSet(watcher, io, gpa, pkg, manifest.*);
        }
    } else |err| {
        try out.print("mana: manifest reload failed ({s}) — keeping last good\n", .{@errorName(err)});
    }

    // Rebuild the world from the current entry scene (last-good-wins).
    const prev_hash = world.stateHash();
    const prev_count = world.count();
    if (engine.scene.reloadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path.*, world)) |_| {
        if (world.stateHash() != prev_hash or world.count() != prev_count) {
            try out.print("mana: reloaded — {d} entities, state hash 0x{x:0>16}\n", .{ world.count(), world.stateHash() });
        } else {
            try out.print("mana: rescanned — no change to the active scene\n", .{});
        }
    } else |err| {
        try out.print("mana: reload failed ({s}) — keeping last good\n", .{@errorName(err)});
    }
    try out.flush();
}

test "runtime can import the engine" {
    try std.testing.expect(engine.ready);
}
