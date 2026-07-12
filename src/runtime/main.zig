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

/// Highest scripting API version this build provides (ADR 0003 gate): the `mana`
/// version under `-Denable-lua`, else 0. A package requesting more is refused.
const provided_script_api: u32 = engine.script_api_version;
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

    // First non-flag argument is the package dir; `--watch` enables hot reload;
    // `--render <out.png>` renders one offscreen frame to a PNG (needs -Denable-vulkan);
    // `--play` runs the live windowed loop (needs -Denable-sdl3 -Denable-vulkan).
    const args = try init.minimal.args.toSlice(arena);
    var pkg_path: ?[]const u8 = null;
    var watch = false;
    var play = false;
    var render_out: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--watch")) {
            watch = true;
        } else if (std.mem.eql(u8, a, "--play")) {
            play = true;
        } else if (std.mem.eql(u8, a, "--render")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --render <out.png>\n");
                try out.flush();
                return;
            }
            render_out = args[i];
        } else if (pkg_path == null) {
            pkg_path = a;
        }
    }

    const pkg = pkg_path orelse {
        try out.writeAll("usage: mana <game-package-dir> [--watch] [--play] [--render <out.png>]\n");
        try out.flush();
        return;
    };
    if (render_out) |path| return runRender(out, io, gpa, pkg, path);
    if (play) return runPlay(out, io, gpa, pkg);
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

/// Load a package's prototype file (ADR 0016) into a parsed `File`, or null if the
/// manifest declares none. Caller owns the result and must `engine.prototype.free`
/// it *after* the `Sim` that borrows its prototypes is torn down (the registry
/// borrows the prototype slice).
fn loadPrototypes(io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !?engine.prototype.File {
    const rel = manifest.prototypes orelse return null;
    const path = try std.fs.path.join(gpa, &.{ pkg, rel });
    defer gpa.free(path);
    const src = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    return try engine.prototype.parse(gpa, src);
}

/// Load a package's Lua handler script (ADR 0003 §1; issue #51) into `sim`, if the
/// manifest declares one. The source is borrowed only for the call (the interpreter
/// compiles it), so it is freed immediately. Under a build without `-Denable-lua`,
/// `Sim.loadScript` is a comptime no-op; the `script_api` gate already refuses a
/// package that *requires* scripting the build lacks (its `script_api` exceeds the
/// provided 0).
fn loadPackageScript(io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest, sim: *engine.Sim) !void {
    const rel = manifest.script orelse return;
    const path = try std.fs.path.join(gpa, &.{ pkg, rel });
    defer gpa.free(path);
    const src = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    try sim.loadScript(src);
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

/// Render a package's scene to a PNG (ADR 0006 M3): iso-project each entity's
/// transform (via `engine.render.project`) and draw it as a quad. The Vulkan branch
/// is comptime-selected, so a default (null-backend) build never references Vulkan
/// and just reports rendering is not compiled in.
fn runRender(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, path: []const u8) !void {
    if (engine.gpu.backend == .vulkan) {
        const manifest = try loadManifest(io, gpa, pkg);
        defer manifest_mod.free(gpa, manifest);
        try checkScriptApi(out, manifest);
        const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
        defer gpa.free(scene_path);
        var world = try engine.scene.loadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path);
        defer world.deinit();

        const view: engine.render.View = .{ .width = 512, .height = 512, .projection = manifest.projection };
        const quads = try engine.render.project(gpa, &world, view, &engine.render.default_palette);
        defer gpa.free(quads);

        const pixels = try engine.gpu.renderScene(gpa, view.width, view.height, quads, .{ 0.09, 0.10, 0.14, 1.0 });
        defer gpa.free(pixels);
        const bytes = try data.png.encode(gpa, view.width, view.height, pixels);
        defer gpa.free(bytes);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        try out.print("mana: rendered '{s}' — {d} entities, {d}x{d} → {s}\n", .{ manifest.name, world.count(), view.width, view.height, path });
    } else {
        try out.writeAll("mana: rendering not compiled in — rebuild with -Denable-vulkan\n");
    }
    try out.flush();
}

/// Live windowed play mode (issue #29; ADR 0009 §6 loop + ADR 0012 present): open a
/// window, build a swapchain from its surface, and run the fixed-timestep loop until the
/// window closes. Gated behind BOTH `-Denable-sdl3` (a real window) and `-Denable-vulkan`
/// (a real swapchain); a build missing either prints a rebuild hint and returns, mirroring
/// how `runRender` guards `-Denable-vulkan`. The windowed path lives in the comptime-true
/// branch (`playLoop`), so a default build never analyzes SDL/Vulkan — invariant #4 stays
/// intact. Present itself needs a display + GPU (a manual acceptance step, not a headless
/// gate). Errors propagate from `playLoop`.
fn runPlay(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8) !void {
    if (engine.gpu.backend == .vulkan and engine.platform.adapter == .sdl3) {
        return playLoop(out, io, gpa, pkg);
    } else {
        try out.writeAll("mana: play mode not compiled in — rebuild with -Denable-sdl3 -Denable-vulkan\n");
        try out.flush();
    }
}

/// The interactive loop for `runPlay` — reached only under `-Denable-sdl3 -Denable-vulkan`
/// (its sole caller is `runPlay`'s comptime-true branch), so SDL/Vulkan types appear only
/// here. Loads the scene into a `Sim` (reusing the `runOnce` load path plus the #30
/// input-translation system so keys drive gameplay), opens the window *before* the
/// `gpu.Device` (ADR 0012 §8: SDL video must be up so the surface extensions resolve),
/// then drives the accumulator loop: poll → tick N fixed steps → render the projected
/// scene into the acquired image → present, recreating the swapchain on out-of-date /
/// suboptimal / resize. Per-frame `project` allocations use a reset arena (matching
/// `runRender`), so no host heap alloc persists across steady-state frames. Pacing is
/// cosmetic — the sim step count is deterministic per elapsed time; sleep/present timing
/// never enters `stateHash` (ADR 0009 §4). Over the ~60-line soft limit by design: this is
/// one cohesive bring-up loop (open resources, then the seam), and splitting the loop body
/// from the resources it drives would only scatter tightly-coupled setup.
fn playLoop(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    // Prototypes (ADR 0016): parsed before the Sim, freed after it (the registry
    // borrows the slice), so `mana.spawn` can resolve package templates.
    const proto_file = try loadPrototypes(io, gpa, pkg, manifest);
    defer if (proto_file) |f| engine.prototype.free(gpa, f);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    if (proto_file) |f| sim.prototypes = .{ .prototypes = f.prototypes };
    try engine.scene.load(parsed, &sim.world);
    try loadPackageScript(io, gpa, pkg, manifest, &sim); // #51: package Lua handlers
    try sim.addSystem(engine.input.inputMoveSystem); // #30: held keys → velocity
    try sim.addSystem(engine.systems.movementSystem);
    try sim.addSystem(engine.systems.regenSystem);

    // Window before device (ADR 0012 §8): SDL video must be initialised so the Vulkan
    // backend can query surface extensions and build the surface.
    var window = try engine.platform.Window.open(gpa, .{ .title = manifest.name });
    defer window.close();
    var dev = try engine.gpu.Device.init(gpa);
    defer dev.deinit();

    const initial = window.size();
    var swapchain = try dev.createSwapchain(.{
        .surface = .{ .native = window.surfaceHandle() },
        .width = initial[0],
        .height = initial[1],
        .format = .rgba8_unorm,
        .present_mode = .fifo,
    });
    defer swapchain.deinit(&dev);
    var pipeline = try dev.createScenePipeline(.rgba8_unorm);
    defer pipeline.deinit(&dev);

    try out.print("mana: playing '{s}' — {d} entities; close the window to exit\n", .{ manifest.name, sim.world.count() });
    try out.flush();

    var frame_arena: std.heap.ArenaAllocator = .init(gpa);
    defer frame_arena.deinit();
    var ts = core.time.FixedTimestep.init(core.time.default_hz);
    var prev = Io.Timestamp.now(io, .awake);
    const clear = [4]f32{ 0.09, 0.10, 0.14, 1.0 };

    while (!window.shouldClose()) {
        sim.setInput(window.poll());

        // Advance the sim by whole fixed steps for the real time elapsed since the last
        // frame (`.awake` = the monotonic clock). The step count is deterministic per
        // elapsed time; the remainder carries in the accumulator.
        const now = Io.Timestamp.now(io, .awake);
        const elapsed_s: f32 = @as(f32, @floatFromInt(prev.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        prev = now;
        for (0..ts.advance(elapsed_s)) |_| try sim.tick();

        const frame = try swapchain.acquire(&dev);
        if (frame.status == .out_of_date) {
            try resizeToWindow(&swapchain, &dev, &window);
            continue;
        }
        _ = frame_arena.reset(.retain_capacity);
        const fa = frame_arena.allocator();
        const size = window.size();
        const view: engine.render.View = .{ .width = size[0], .height = size[1], .projection = manifest.projection };
        const quads = try engine.render.project(fa, &sim.world, view, &engine.render.default_palette);
        try engine.gpu.renderQuads(fa, &dev, &pipeline, frame.target, quads, clear);
        switch (try swapchain.present(&dev, frame)) {
            .out_of_date, .suboptimal => try resizeToWindow(&swapchain, &dev, &window),
            .optimal => {},
        }
    }
}

/// Recreate `swapchain` to `window`'s current drawable size (on out-of-date / suboptimal /
/// resize). A thin wrapper so the loop states the intent once. Reached only under the play
/// flags (called only from `playLoop`), so its swapchain/window types are analyzed only
/// then. Errors propagate from `Swapchain.resize`.
fn resizeToWindow(swapchain: *engine.gpu.Swapchain, dev: *engine.gpu.Device, window: *engine.platform.Window) !void {
    const s = window.size();
    try swapchain.resize(dev, s[0], s[1]);
}

/// One-shot: load the scene into a `Sim`, register systems, advance `tick_steps`,
/// print the deterministic state hash.
fn runOnce(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    // Prototypes (ADR 0016): parsed before the Sim and freed after it (the registry
    // borrows the slice), so `mana.spawn` can resolve package templates.
    const proto_file = try loadPrototypes(io, gpa, pkg, manifest);
    defer if (proto_file) |f| engine.prototype.free(gpa, f);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    if (proto_file) |f| sim.prototypes = .{ .prototypes = f.prototypes };
    try engine.scene.load(parsed, &sim.world);
    try loadPackageScript(io, gpa, pkg, manifest, &sim); // #51: package Lua handlers
    try sim.addSystem(engine.systems.movementSystem);
    try sim.addSystem(engine.systems.regenSystem);
    try sim.run(tick_steps);

    try out.print(
        "mana: ran '{s}' v{s} — {d} entities, {d} ticks, state hash 0x{x:0>16}\n",
        .{ manifest.name, manifest.version, sim.world.count(), sim.tick_count, sim.stateHash() },
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
