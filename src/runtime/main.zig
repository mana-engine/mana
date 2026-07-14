//! runtime — the `mana` runner executable. Loads a game content package by path,
//! parses its `game.zon` manifest and entry scene, and either runs a fixed number
//! of deterministic steps and prints a state hash (default), or watches the whole
//! package — the manifest plus every referenced scene — and hot-reloads on change
//! (`--watch`, ADR 0005). It knows the manifest *format* but never any specific
//! game; nothing here references `games/**`.
//!
//! Over the ~500-line soft limit by design: this is the single runner entry point,
//! and each mode (`--watch`/`--play`/`--render`/`--render-svg`/`--filmstrip`/
//! `--scenario`) shares the same small set of load-path helpers below
//! (`loadManifest`, `loadPrototypes`, `loadPackageScript`, `registerStandardSystems`)
//! rather than duplicating them across files — splitting by mode would scatter that
//! shared setup instead of removing it.

const std = @import("std");
const core = @import("core");
const tracy = core.tracy;
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
/// Pixel dimensions for `--render-svg`/`--filmstrip` (ADR 0029) — matches `runRender`'s
/// PNG size so an SVG and a PNG render of the same scene are directly comparable.
const svg_view_size: u32 = 512;
/// Default tick count for `--filmstrip` when `--ticks` is not given.
const filmstrip_default_ticks: u32 = 60;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Route the engine allocator through Tracy's memory profiler (ADR 0023). Under a
    // default build this hands back `init.gpa` unchanged (zero overhead); under
    // `-Denable-tracy` every alloc/free is reported. `tracing` outlives the whole run.
    var tracing = tracy.TracingAllocator.init(init.gpa);
    const gpa = tracing.allocator();
    const arena = init.arena.allocator();

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    // First non-flag argument is the package dir; `--watch` enables hot reload;
    // `--render <out.png>` renders one offscreen frame to a PNG (needs -Denable-vulkan);
    // `--render-svg <out.svg>` renders one frame to SVG, no GPU needed (ADR 0029);
    // `--filmstrip <out-dir> [--ticks N]` runs N ticks, writing one SVG per tick
    // (ADR 0029); `--play` runs the live windowed loop (needs -Denable-sdl3 -Denable-vulkan).
    const args = try init.minimal.args.toSlice(arena);
    var pkg_path: ?[]const u8 = null;
    var watch = false;
    var play = false;
    var render_out: ?[]const u8 = null;
    var render_svg_out: ?[]const u8 = null;
    var filmstrip_dir: ?[]const u8 = null;
    var filmstrip_ticks: u32 = filmstrip_default_ticks;
    var scenario_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--watch")) {
            watch = true;
        } else if (std.mem.eql(u8, a, "--play")) {
            play = true;
        } else if (std.mem.eql(u8, a, "--scenario")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --scenario <scenario.zon>\n");
                try out.flush();
                return;
            }
            scenario_path = args[i];
        } else if (std.mem.eql(u8, a, "--render")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --render <out.png>\n");
                try out.flush();
                return;
            }
            render_out = args[i];
        } else if (std.mem.eql(u8, a, "--render-svg")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --render-svg <out.svg>\n");
                try out.flush();
                return;
            }
            render_svg_out = args[i];
        } else if (std.mem.eql(u8, a, "--filmstrip")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --filmstrip <out-dir> [--ticks N]\n");
                try out.flush();
                return;
            }
            filmstrip_dir = args[i];
        } else if (std.mem.eql(u8, a, "--ticks")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --filmstrip <out-dir> [--ticks N]\n");
                try out.flush();
                return;
            }
            filmstrip_ticks = std.fmt.parseInt(u32, args[i], 10) catch {
                try out.print("mana: invalid --ticks value '{s}'\n", .{args[i]});
                try out.flush();
                return;
            };
        } else if (pkg_path == null) {
            pkg_path = a;
        }
    }

    const pkg = pkg_path orelse {
        try out.writeAll(
            "usage: mana <game-package-dir> [--watch] [--play] [--render <out.png>] " ++
                "[--render-svg <out.svg>] [--filmstrip <out-dir> [--ticks N]] " ++
                "[--scenario <scenario.zon>]\n",
        );
        try out.flush();
        return;
    };
    if (render_out) |path| return runRender(out, io, gpa, pkg, path);
    if (render_svg_out) |path| return runRenderSvg(out, io, gpa, pkg, path);
    if (filmstrip_dir) |dir| return runFilmstrip(out, io, gpa, pkg, dir, filmstrip_ticks);
    if (scenario_path) |path| return runScenario(out, io, gpa, pkg, path);
    if (play) return runPlay(out, io, gpa, pkg);
    if (watch) return runWatch(out, io, gpa, pkg);
    return runOnce(out, io, gpa, pkg);
}

/// Register the engine's standard per-tick system set on `sim`, in the fixed order
/// every package runs them — documented here (in one place) so the one-shot and the
/// interactive loop stay identical and no genre concept leaks into the runner. The
/// order is load-bearing:
///
///   nav → movement → collision → regen
///
/// - `nav` (ADR 0027) steers each `NavAgent` by writing its `Velocity` toward the next
///   cell on its path; it runs *before* `movement` so that velocity is integrated the
///   same tick.
/// - `movement` integrates `Velocity` into `Transform`.
/// - `collision` (ADR 0008/0025) runs *after* `movement` so the overlaps it finds — and
///   the `on_collision_begin` events they raise — reflect this tick's post-move
///   positions.
/// - `regen` advances health toward max; it touches a disjoint column (healths), so its
///   placement is order-independent — last by convention.
///
/// Registering nav/collision unconditionally is a genre-neutral no-op for a package
/// that uses neither: `nav` no-ops without a `Sim.tilemap` + agents (ADR 0027), and
/// `collision` raises no events when fewer than two entities carry a `Collider` — so a
/// package with no tilemap/agents/colliders (snake, sandbox, chronicle) ticks
/// bit-identically to before this set existed. Input translation (#30, interactive loop
/// only) is registered by the caller *before* this call, so held keys reach
/// `nav`/`movement` the same tick.
fn registerStandardSystems(sim: *engine.Sim) Allocator.Error!void {
    try sim.addSystem(engine.nav.navSystem);
    try sim.addSystem(engine.systems.movementSystem);
    try sim.addSystem(engine.collision.collisionSystem);
    try sim.addSystem(engine.systems.regenSystem);
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

/// Render a package's scene to an SVG (ADR 0029): project the entry scene (via
/// `engine.render.project`) and emit `engine.render_svg.toSvg`. Same load path as
/// `runRender` (manifest → scene, no ticking, no script) but needs **no GPU** — SVG is
/// text, not a rasterized image — so, unlike `--render`, this works on the DEFAULT
/// build. Genre-neutral: it draws whatever the projected quads are.
fn runRenderSvg(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, path: []const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);
    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    var world = try engine.scene.loadWorldFromFile(gpa, io, Io.Dir.cwd(), scene_path);
    defer world.deinit();

    const view: engine.render.View = .{ .width = svg_view_size, .height = svg_view_size, .projection = manifest.projection };
    const quads = try engine.render.project(gpa, &world, view, &engine.render.default_palette);
    defer gpa.free(quads);
    const svg = try engine.render_svg.toSvg(gpa, quads, view, engine.render_svg.default_background);
    defer gpa.free(svg);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = svg });
    try out.print("mana: rendered '{s}' — {d} entities, {d}x{d} → {s}\n", .{ manifest.name, world.count(), view.width, view.height, path });
    try out.flush();
}

/// Scrub a headless playthrough (ADR 0029): build a full `Sim` — the same load path as
/// `runOnce` (standard systems, package script, prototypes) — advance it `ticks` fixed
/// steps, and write one SVG per tick to `dir/frame_NNNN.svg` (4-digit, zero-padded).
/// Frame `frame_0000.svg` is the state *after* the first tick (so `on_scene_enter`'s
/// spawns are already visible, matching `runOnce`'s "fires on the first tick" note).
/// Lets a human scrub ghosts nav-moving and pickups getting eaten entirely offscreen.
/// Deliberately does not accept an input trace — that is the scenario-test harness's
/// concern (ADR 0028, separate lane); this only free-runs the sim.
fn runFilmstrip(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, dir: []const u8, ticks: u32) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    const proto_file = try loadPrototypes(io, gpa, pkg, manifest);
    defer if (proto_file) |f| engine.prototype.free(gpa, f);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    if (proto_file) |f| sim.prototypes = .{ .prototypes = f.prototypes };
    try engine.scene.load(parsed, &sim.world);
    if (parsed.tilemap) |*tm| sim.tilemap = tm; // see runOnce: parsed outlives sim (LIFO defers)
    try loadPackageScript(io, gpa, pkg, manifest, &sim);
    sim.enterScene(parsed.name);
    try registerStandardSystems(&sim);

    try Io.Dir.cwd().createDirPath(io, dir);
    const view: engine.render.View = .{ .width = svg_view_size, .height = svg_view_size, .projection = manifest.projection };

    var name_buf: [32]u8 = undefined;
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        try sim.tick();
        const quads = try engine.render.project(gpa, &sim.world, view, &engine.render.default_palette);
        defer gpa.free(quads);
        const svg = try engine.render_svg.toSvg(gpa, quads, view, engine.render_svg.default_background);
        defer gpa.free(svg);
        const name = try std.fmt.bufPrint(&name_buf, "frame_{d:0>4}.svg", .{t});
        const frame_path = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(frame_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = frame_path, .data = svg });
    }
    try out.print("mana: filmstrip '{s}' — {d} frames, {d}x{d} → {s}\n", .{ manifest.name, ticks, view.width, view.height, dir });
    try out.flush();
}

/// Run a data-driven scenario (ADR 0028 layer 2, issue #94): load `pkg` exactly as
/// `runOnce` does (manifest → scene → prototypes → script → standard systems), then
/// replay `scenario_path`'s input trace against the live `Sim` via the generic
/// `engine.scenario.run` referee — never any genre knowledge here, only the package
/// load path every other mode already shares. Prints one line per assertion in file
/// order (so a red line names the exact broken mechanic), then a summary; a failed
/// assertion or an aborting Layer-1 invariant violation makes the process exit
/// non-zero (`error.ScenarioFailed`) so `--scenario` is CI-usable.
fn runScenario(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, scenario_path: []const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    const proto_file = try loadPrototypes(io, gpa, pkg, manifest);
    defer if (proto_file) |f| engine.prototype.free(gpa, f);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    if (proto_file) |f| sim.prototypes = .{ .prototypes = f.prototypes };
    try engine.scene.load(parsed, &sim.world);
    if (parsed.tilemap) |*tm| sim.tilemap = tm; // see runOnce: parsed outlives sim (LIFO defers)
    try loadPackageScript(io, gpa, pkg, manifest, &sim);
    sim.enterScene(parsed.name);
    try registerStandardSystems(&sim);

    const scenario_src = try Io.Dir.cwd().readFileAllocOptions(io, scenario_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scenario_src);
    const scenario = try engine.scenario.parse(gpa, scenario_src);
    defer engine.scenario.free(gpa, scenario);

    var report = try engine.scenario.run(gpa, &sim, scenario);
    defer report.deinit();

    var passed_n: usize = 0;
    for (report.results.items) |r| {
        try out.print("mana: [{s}] {s} (tick {d})\n", .{ if (r.passed) "PASS" else "FAIL", r.label, r.at_tick });
        if (r.passed) {
            passed_n += 1;
        } else if (r.detail.len > 0) {
            try out.print("       {s}\n", .{r.detail});
        }
    }
    if (report.invariant_violation) |iv| {
        try out.print("mana: [FAIL] invariant violated at tick {d}: {f}\n", .{ iv.tick, iv.violation });
    }
    try out.print(
        "mana: scenario '{s}' — {d}/{d} assertions passed\n",
        .{ scenario_path, passed_n, report.results.items.len },
    );
    try out.flush();
    if (!report.passed()) return error.ScenarioFailed;
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
    // Same tilemap borrow as the one-shot path (see runOnce): `parsed` outlives `sim`
    // (LIFO defers), so nav can path over the scene's grid; null ⇒ nav no-ops.
    if (parsed.tilemap) |*tm| sim.tilemap = tm;
    try loadPackageScript(io, gpa, pkg, manifest, &sim); // #51: package Lua handlers
    sim.enterScene(parsed.name); // #54/ADR 0017: fire on_scene_enter on the first tick
    try sim.addSystem(engine.input.inputMoveSystem); // #30: held keys → velocity (before nav)
    try registerStandardSystems(&sim);

    // Load the sprite sheets this scene could reference (issue #113 phase 2; ADR 0031
    // §2; phase 2b lifecycle fix): the DERIVED `.msf` artifacts under
    // `<pkg>/.../generated/` (built by `mise run assets`) for BOTH `sim.world`'s live
    // `Sprite` components AND `sim.prototypes`. The latter matters here — `enterScene`
    // above only QUEUES `on_scene_enter` to fire on the first `sim.tick()` in the loop
    // below, and it's that scene's Lua handler that spawns sprited entities (e.g. pac
    // and the ghosts via `mana.spawn` in `games/pacman/rules.lua`), so `sim.world` is
    // still empty right here. Without the prototype half, the atlas built below would
    // be zero-sized and no sprite would ever render (ADR 0031 §4). Decoded once here;
    // each frame the animation cursor is advanced from wall-clock time below.
    var sheets = try engine.sprite.loadForScene(gpa, io, Io.Dir.cwd(), pkg, &sim.world, sim.prototypes);
    defer sheets.deinit();

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

    // Sprite path (issue #113 phase 2b; ADR 0031 §4): pack every loaded sheet's frames
    // into one atlas, upload it to a single GPU texture once, and build the textured
    // pipeline that samples it. `--play` then draws each sprited entity as a textured,
    // direction-facing quad over the flat scene quads (see the render zone below). A scene
    // with no (generated) sheets yields a zero-sized atlas: no texture, no sprite pass —
    // every entity keeps its flat `Appearance` quad.
    var atlas = try engine.sprite.buildAtlas(gpa, &sheets);
    defer atlas.deinit();
    var sprite_pipeline = try dev.createTexturedPipeline(.rgba8_unorm);
    defer sprite_pipeline.deinit(&dev);
    var atlas_tex: ?engine.gpu.Texture = null;
    defer if (atlas_tex) |*t| t.deinit(&dev);
    if (atlas.width > 0) {
        var t = try dev.createTexture(.{
            .width = atlas.width,
            .height = atlas.height,
            .format = .rgba8_unorm,
            .usage = .{ .transfer_dst = true, .sampled = true },
        });
        errdefer t.deinit(&dev);
        try dev.uploadTexture(&t, atlas.pixels);
        atlas_tex = t;
    }

    try out.print("mana: playing '{s}' — {d} entities; close the window to exit\n", .{ manifest.name, sim.world.count() });
    try out.flush();

    var frame_arena: std.heap.ArenaAllocator = .init(gpa);
    defer frame_arena.deinit();
    var ts = core.time.FixedTimestep.init(core.time.default_hz);
    var prev = Io.Timestamp.now(io, .awake);
    const clear = [4]f32{ 0.09, 0.10, 0.14, 1.0 };

    // Live FPS/tick readout in the window title, refreshed once per wall-clock second.
    // The sim tick count rising steadily (independent of frames) is the visible proof
    // that gameplay is timer-driven, not frame- or input-driven.
    var frames: u32 = 0;
    var fps_window_s: f32 = 0;
    var title_buf: [128]u8 = undefined;

    while (!window.shouldClose()) {
        // One Tracy frame boundary per loop iteration (ADR 0023), marked first so
        // every iteration — including the out-of-date `continue` below — counts.
        tracy.frameMark();
        {
            const z = tracy.zone(@src(), "poll");
            defer z.end();
            sim.setInput(window.poll());
        }

        // Advance the sim by whole fixed steps for the real time elapsed since the last
        // frame (`.awake` = the monotonic clock). The step count is deterministic per
        // elapsed time; the remainder carries in the accumulator.
        const now = Io.Timestamp.now(io, .awake);
        const elapsed_s: f32 = @as(f32, @floatFromInt(prev.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        prev = now;
        const steps = ts.advance(elapsed_s);
        {
            const z = tracy.zone(@src(), "tick");
            defer z.end();
            for (0..steps) |_| try sim.tick();
        }

        // Cosmetic sprite animation advances by WALL-CLOCK elapsed time, never a sim
        // tick, so it stays out of `stateHash` (ADR 0031 §1; issue #113 item 3).
        engine.sprite.advance(&sim.world, &sheets, elapsed_s);

        // Plots (ADR 0023): live app-state time series. fps guards a zero-length frame;
        // tick_rate is steps advanced this frame; entities is the live world count.
        // Script cost is surfaced via the `script.*`/`sim.dispatch` zones instead.
        if (elapsed_s > 0) tracy.plot("fps", 1.0 / @as(f64, elapsed_s));
        tracy.plot("tick_rate", @floatFromInt(steps));
        tracy.plot("entities", @floatFromInt(sim.world.count()));

        const frame = try swapchain.acquire(&dev);
        if (frame.status == .out_of_date) {
            try resizeToWindow(&swapchain, &dev, &window);
            continue;
        }
        {
            const z = tracy.zone(@src(), "render");
            defer z.end();
            _ = frame_arena.reset(.retain_capacity);
            const fa = frame_arena.allocator();
            const size = window.size();
            const view: engine.render.View = .{ .width = size[0], .height = size[1], .projection = manifest.projection };
            const quads = try engine.render.project(fa, &sim.world, view, &engine.render.default_palette);
            // Textured sprite quads (ADR 0031 §4): the current animation frame's atlas
            // sub-rect, tinted and rotated to face travel; drawn over the flat quads.
            const sprite_quads = try engine.render.projectSprites(fa, &sim.world, view, &sheets, &atlas);
            const atlas_ptr: ?*engine.gpu.Texture = if (atlas_tex) |*t| t else null;
            try engine.gpu.renderFrame(fa, &dev, &pipeline, &sprite_pipeline, atlas_ptr, frame.target, quads, sprite_quads, clear);
        }
        {
            const z = tracy.zone(@src(), "present");
            defer z.end();
            switch (try swapchain.present(&dev, frame)) {
                .out_of_date, .suboptimal => try resizeToWindow(&swapchain, &dev, &window),
                .optimal => {},
            }
        }

        frames += 1;
        fps_window_s += elapsed_s;
        if (fps_window_s >= 1.0) {
            const fps = @as(f32, @floatFromInt(frames)) / fps_window_s;
            const title = std.fmt.bufPrintZ(&title_buf, "{s} — {d:.0} fps · {d} ticks", .{ manifest.name, fps, sim.tick_count }) catch "mana";
            window.setTitle(title);
            frames = 0;
            fps_window_s = 0;
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
    // Point the sim at the scene's grid level (ADR 0026/0027), if any, so `navSystem`
    // can path over it. `parsed` outlives `sim` — its `defer scene.free` was registered
    // before `sim`'s `defer deinit`, and defers run LIFO, so the sim is torn down first
    // and this borrow never dangles. Null tilemap ⇒ nav no-ops (see registerStandardSystems).
    if (parsed.tilemap) |*tm| sim.tilemap = tm;
    try loadPackageScript(io, gpa, pkg, manifest, &sim); // #51: package Lua handlers
    sim.enterScene(parsed.name); // #54/ADR 0017: fire on_scene_enter on the first tick
    try registerStandardSystems(&sim);
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
