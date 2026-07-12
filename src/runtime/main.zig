//! runtime — the `mana` runner executable. Loads a game content package by path,
//! parses its `game.zon` manifest and entry scene, and either runs a fixed number
//! of deterministic steps and prints a state hash (default), or watches the scene
//! file and hot-reloads on change (`--watch`, ADR 0005). It knows the manifest
//! *format* but never any specific game; nothing here references `games/**`.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const engine = @import("engine");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

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

    // Parse args: the first non-flag argument is the package dir; `--watch` enables
    // hot reload.
    const args = try init.minimal.args.toSlice(arena);
    var pkg_path: ?[]const u8 = null;
    var watch = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--watch")) {
            watch = true;
        } else if (pkg_path == null) {
            pkg_path = a;
        }
    }
    const pkg = pkg_path orelse {
        try out.writeAll("usage: mana <game-package-dir> [--watch]\n");
        try out.flush();
        return;
    };

    // Load and parse the manifest.
    const manifest_path = try std.fs.path.join(arena, &.{ pkg, "game.zon" });
    const manifest_src = try Io.Dir.cwd().readFileAllocOptions(io, manifest_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(manifest_src);
    const manifest = try manifest_mod.parse(gpa, manifest_src);
    defer manifest_mod.free(gpa, manifest);

    // Gate on the scripting API the package requires (ADR 0003 §5).
    if (manifest.script_api > provided_script_api) {
        try out.print(
            "mana: '{s}' requires scripting API v{d}, but this build provides v{d}\n",
            .{ manifest.name, manifest.script_api, provided_script_api },
        );
        try out.flush();
        return error.UnsupportedScriptApi;
    }

    const scene_path = try std.fs.path.join(arena, &.{ pkg, manifest.entry_scene });

    // Build the initial world from the entry scene.
    var world = try engine.scene.loadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path);
    defer world.deinit();

    if (!watch) {
        // One-shot: advance deterministic fixed steps and report the state hash.
        for (0..tick_steps) |_| engine.systems.movement(&world, core.time.default_dt);
        try out.print(
            "mana: ran '{s}' v{s} — {d} entities, {d} ticks, state hash 0x{x:0>16}\n",
            .{ manifest.name, manifest.version, world.count(), tick_steps, world.stateHash() },
        );
        try out.flush();
        return;
    }

    // Watch mode: tick, poll the scene file, hot-reload on change (last-good-wins).
    var watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer watcher.deinit();
    try watcher.add(io, scene_path);
    try out.print("mana: watching '{s}' — edit {s} to hot-reload (Ctrl-C to stop)\n", .{ manifest.name, scene_path });
    try out.flush();

    while (true) {
        engine.systems.movement(&world, core.time.default_dt);
        if (watcher.poll(io)) {
            if (engine.scene.reloadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path, &world)) |_| {
                try out.print("mana: reloaded — {d} entities, state hash 0x{x:0>16}\n", .{ world.count(), world.stateHash() });
            } else |err| {
                try out.print("mana: reload failed ({s}) — keeping last good\n", .{@errorName(err)});
            }
            try out.flush();
        }
        try Io.sleep(io, Io.Duration.fromMilliseconds(watch_poll_ms), .awake);
    }
}

test "runtime can import the engine" {
    try std.testing.expect(engine.ready);
}
