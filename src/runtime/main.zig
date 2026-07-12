//! runtime — the `mana` runner executable. Loads a game content package by path,
//! parses its `game.zon` manifest and entry scene, runs the headless simulation a
//! fixed number of deterministic steps, and prints a state hash. It knows the
//! manifest *format* but never any specific game; nothing here references
//! `games/**` — the package path is data supplied at runtime.

const std = @import("std");
const core = @import("core");
const engine = @import("engine");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

/// Highest scripting API version this build provides (ADR 0003 gate). 0 = no
/// scripting compiled in yet; a package requesting more is refused.
const provided_script_api: u32 = 0;
/// Number of fixed steps a headless run advances before reporting.
const tick_steps: u32 = 60;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.writeAll("usage: mana <game-package-dir>\n");
        try out.flush();
        return;
    }
    const pkg_path = args[1];

    // Load and parse the manifest.
    const manifest_path = try std.fs.path.join(arena, &.{ pkg_path, "game.zon" });
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

    // Load and parse the entry scene it points at.
    const scene_path = try std.fs.path.join(arena, &.{ pkg_path, manifest.entry_scene });
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    // Build the world, advance deterministic fixed steps, and report the state hash.
    var world = try engine.scene.toWorld(gpa, scene);
    defer world.deinit();
    for (0..tick_steps) |_| engine.systems.movement(&world, core.time.default_dt);

    try out.print(
        "mana: ran '{s}' v{s} — {d} entities, {d} ticks, state hash 0x{x:0>16}\n",
        .{ manifest.name, manifest.version, world.count(), tick_steps, world.stateHash() },
    );
    try out.flush();
}

test "runtime can import the engine" {
    try std.testing.expect(engine.ready);
}
