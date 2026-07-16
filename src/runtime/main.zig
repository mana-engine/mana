//! runtime — the `mana` runner executable. Loads a game content package by path,
//! parses its `game.zon` manifest and entry scene, and either runs a fixed number
//! of deterministic steps and prints a state hash (default), or watches the whole
//! package — the manifest plus its globbed content directories (ADR 0038) — and
//! hot-reloads on change (`--watch`, ADR 0005). It knows the manifest *format* and the
//! package directory conventions but never any specific
//! game; nothing here references `games/**`.
//!
//! Over the ~500-line soft limit by design: this is the single runner entry point,
//! and each mode (`--watch`/`--play`/`--render`/`--render-play-frame`/`--render-svg`/
//! `--filmstrip`/`--scenario`) shares the same small set of load-path helpers below
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
/// The same cadence in seconds, for `--play`'s wall-clock-accumulator poll of the
/// action-binding files (ADR 0041 §3) — `playLoop` has no sleep to hang it off, so it
/// counts elapsed frame time instead of blocking like `runWatch` does.
const watch_poll_s: f32 = @as(f32, @floatFromInt(watch_poll_ms)) / std.time.ms_per_s;
/// Pixel dimensions for `--render-svg`/`--filmstrip` (ADR 0029) — matches `runRender`'s
/// PNG size so an SVG and a PNG render of the same scene are directly comparable.
const svg_view_size: u32 = 512;
/// Package-relative path to the v1 user action-binding override (ADR 0041 §2.1
/// accepted Option B: package-local `save/`, mirroring #135's `save/settings.zon`;
/// zero new path code — a package-relative join like every other content path. Moving
/// this to an OS config dir is the deferred, isolated follow-up #240.
const action_override_rel = "save/input.zon";
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
    // `--render-play-frame <out.png> [--ticks N]` captures the `--play` textured-sprite
    // composite headlessly (null backend, no GPU) after N fixed ticks (issue #122);
    // `--render-svg <out.svg>` renders one frame to SVG, no GPU needed (ADR 0029);
    // `--filmstrip <out-dir> [--ticks N]` runs N ticks, writing one SVG per tick
    // (ADR 0029) — free-running, OR, when `--scenario <trace.zon>` is *also* given,
    // replaying that scenario's `input_trace` (keyboard AND injected gamepad, ADR 0040
    // §5) one snapshot per tick so a human can scrub a controller-driven playthrough
    // headlessly (issue #222); `--play` runs the live windowed loop (needs -Denable-sdl3 -Denable-vulkan).
    const args = try init.minimal.args.toSlice(arena);
    var pkg_path: ?[]const u8 = null;
    var watch = false;
    var play = false;
    var render_out: ?[]const u8 = null;
    var render_play_out: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--render-play-frame")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("usage: mana <pkg> --render-play-frame <out.png> [--ticks N]\n");
                try out.flush();
                return;
            }
            render_play_out = args[i];
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
                "[--render-play-frame <out.png> [--ticks N]] " ++
                "[--render-svg <out.svg>] [--filmstrip <out-dir> [--ticks N]] " ++
                "[--scenario <scenario.zon>]\n",
        );
        try out.flush();
        return;
    };
    if (render_out) |path| return runRender(out, io, gpa, pkg, path);
    if (render_play_out) |path| return runRenderPlayFrame(out, io, gpa, pkg, path, filmstrip_ticks);
    if (render_svg_out) |path| return runRenderSvg(out, io, gpa, pkg, path);
    if (filmstrip_dir) |dir| return runFilmstrip(out, io, gpa, pkg, dir, filmstrip_ticks, scenario_path);
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

/// Load and merge the package's `prototypes/` directory (ADR 0016; ADR 0038 §2) into
/// a `Set`: every `prototypes/*.zon` file, globbed, byte-lexicographically sorted, and
/// concatenated into one template list (a duplicate name across files is a hard error).
/// A package with no `prototypes/` directory yields an empty set (`mana.spawn` then
/// resolves nothing). Caller owns the result and must `Set.deinit` it *after* the `Sim`
/// that borrows its prototypes is torn down (the registry borrows the merged slice).
fn loadPrototypes(io: Io, gpa: Allocator, pkg: []const u8) !engine.prototype.Set {
    return engine.prototype.loadDir(gpa, io, Io.Dir.cwd(), pkg);
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

/// The outcome of one `loadEffectiveActionMap` attempt: the owned effective map (null
/// when the package declares no `input` and has no usable override) plus whether the
/// user override was *present but rejected*. The two callers want different things from
/// that flag, which is why it is reported rather than swallowed: startup
/// (`loadActionMap`) proceeds with the package-only map — there is no earlier map to
/// keep — while a live reload (`ActionMapState.reload`) discards this result and keeps
/// the current effective map, exactly ADR 0041 §3's last-good-wins. `map` is owned by
/// the caller either way; free it with `engine.action_map.free`.
const ActionMapLoad = struct {
    map: ?engine.ActionMap,
    override_rejected: bool = false,
};

/// Load a package's *effective* action-binding table: the package `input.zon` (ADR
/// 0040 §3, issue #216) if the manifest declares an `input` path, with a v1 user
/// override (ADR 0041 §2, issue #236) merged OVER it when one exists at the
/// package-local `action_override_rel` path (ADR 0041 §2.1's accepted Option B).
///
/// **The package map is load-bearing; the override is best-effort.** A declared
/// `.input` that fails to read or parse fails this load — that is shipped content,
/// expected to be well-formed. The *override*, by contrast, is player-editable/
/// engine-written state: if `action_override_rel` is absent, the package map is
/// returned as-is (no log — "absent" is not an error). If it is present but fails to
/// parse or fails to `engine.action_map.merge` (an unknown action, a `type` mismatch,
/// or an analog-rule violation), the failure is logged to `out` and the returned
/// `map` is the package-only map with `override_rejected = true`.
///
/// The caller owns `map` and must `engine.action_map.free` it *after* any `Sim` that
/// borrows it is torn down. Errors: file-read failures for the *package* map, plus
/// `engine.action_map.parse`'s `ParseZon`/`Unbound`/`WrongTypedSource`/`OutOfMemory`
/// — for the package map only.
fn loadEffectiveActionMap(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !ActionMapLoad {
    var pkg_map: ?engine.ActionMap = null;
    if (manifest.input) |rel| {
        const path = try std.fs.path.join(gpa, &.{ pkg, rel });
        defer gpa.free(path);
        const src = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(src);
        pkg_map = try engine.action_map.parse(gpa, src);
    }
    errdefer if (pkg_map) |m| engine.action_map.free(gpa, m);

    // The override is best-effort (a bad one falls back to the package-only map,
    // last-good spirit ADR 0041 §3) — but only for *benign* failures. A resource
    // error like `OutOfMemory` is a real bug, not a malformed override, so it
    // propagates rather than being masked as a "using package input only" log line —
    // the same benign-case/`else => return err` split `watchDir` uses.
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);
    const override_src = Io.Dir.cwd().readFileAllocOptions(io, override_path, gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
        // No override file at all ⇒ package map only, silently (the common case).
        error.FileNotFound => return .{ .map = pkg_map },
        else => return err,
    };
    defer gpa.free(override_src);

    const override_map = engine.action_map.parse(gpa, override_src) catch |err| switch (err) {
        // A malformed/invalid override file: log and fall back to the package map.
        error.ParseZon, error.Unbound, error.WrongTypedSource => {
            try logOverrideFallback(out, override_path, "failed to parse", err);
            return .{ .map = pkg_map, .override_rejected = true };
        },
        error.OutOfMemory => return err,
    };
    defer engine.action_map.free(gpa, override_map);

    const base = pkg_map orelse engine.ActionMap{};
    const effective = engine.action_map.merge(gpa, base, override_map) catch |err| switch (err) {
        // The override parses but doesn't apply cleanly over the package map: log and
        // fall back (an unknown action, a `type` mismatch, or an analog-rule violation).
        error.UnknownAction, error.TypeMismatch, error.Unbound, error.WrongTypedSource => {
            try logOverrideFallback(out, override_path, "rejected", err);
            return .{ .map = pkg_map, .override_rejected = true };
        },
        error.OutOfMemory => return err,
    };
    if (pkg_map) |m| engine.action_map.free(gpa, m);
    return .{ .map = effective };
}

/// Startup half of the effective action-map load: `loadEffectiveActionMap` with the
/// override-rejection flag dropped, because at startup there is no earlier map to keep
/// — a bad override simply yields the package-only map (never crashing startup, ADR
/// 0041 §3's last-good-wins spirit). Returns the owned, effective `ActionMap` the
/// caller borrows onto `Sim.action_map` (mirroring how the scene's `tilemap` is
/// borrowed), or null when the package has neither a declared `input` nor a usable
/// override. The caller owns the result and must `engine.action_map.free` it *after*
/// the `Sim` that borrows it is torn down. Errors: as `loadEffectiveActionMap`.
fn loadActionMap(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !?engine.ActionMap {
    const loaded = try loadEffectiveActionMap(out, io, gpa, pkg, manifest);
    return loaded.map;
}

/// The single owner of a live, reloadable effective action map (ADR 0041 §3, issue
/// #237) — the `--play` counterpart of the one-shot `loadActionMap` + `defer free`
/// pair the headless modes use.
///
/// **Ownership.** `map` is the one owned effective `ActionMap`; nothing else frees it.
/// `deinit` frees whatever is current. `Sim.action_map` borrows `&state.map.?`, a
/// pointer *into this struct*, so the borrow's address is stable for the state's whole
/// lifetime: `reload` replaces the optional's payload **in place** and frees the old
/// map only after the new one is fully built, so no dangling reference to a freed map
/// can survive a swap. The state must outlive the `Sim` that borrows it (LIFO defers
/// in `playLoop`, exactly as the parsed scene's `tilemap` borrow is scoped).
///
/// `borrow()` is the single source of that pointer, and callers re-assign
/// `sim.action_map = state.borrow()` after every `reload` rather than pointing at it
/// once at load: the payload address is stable but its *presence* is `reload`'s to
/// decide, and nothing here should encode which of the two a given package happens to
/// resolve to.
const ActionMapState = struct {
    gpa: Allocator,
    map: ?engine.ActionMap,

    /// Take ownership of an already-loaded effective map (`loadActionMap`'s result).
    fn init(gpa: Allocator, map: ?engine.ActionMap) ActionMapState {
        return .{ .gpa = gpa, .map = map };
    }

    fn deinit(self: *ActionMapState) void {
        if (self.map) |m| engine.action_map.free(self.gpa, m);
        self.* = undefined;
    }

    /// The borrow to hand `Sim.action_map`: a pointer into `self` (stable), or null
    /// when the package currently resolves no bindings at all. `self` must outlive
    /// every `Sim` given this pointer.
    fn borrow(self: *ActionMapState) ?*const engine.ActionMap {
        return if (self.map) |*m| m else null;
    }

    /// Re-read the package `input.zon` + the user override, re-merge them, and swap
    /// `map` to the fresh effective map, freeing the previous one — **last-good-wins**
    /// (ADR 0005 §3, ADR 0041 §3): if the package map fails to read/parse, or the
    /// override is present but rejected, the current `map` is kept untouched and the
    /// failure is logged to `out`. A malformed edit therefore never clears bindings and
    /// never crashes the session; the next change retries.
    ///
    /// Call only at a tick boundary — the swap is atomic from the sim's view (the map
    /// is a pure lookup table the resolver reads per tick, ADR 0040 §4), but only if no
    /// tick is mid-flight. Allocates only when a change was detected, so the
    /// steady-state loop stays alloc-free. Errors: `error.OutOfMemory` only (a real
    /// resource failure, never a content error — those are the logged, kept-last-good
    /// cases).
    fn reload(self: *ActionMapState, out: *Io.Writer, io: Io, pkg: []const u8, manifest: Manifest) !void {
        const loaded = loadEffectiveActionMap(out, io, self.gpa, pkg, manifest) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.print("mana: input reload failed ({s}) — keeping last good bindings\n", .{@errorName(err)});
                try out.flush();
                return;
            },
        };
        if (loaded.override_rejected) {
            // `loadEffectiveActionMap` already logged *why*; its package-only fallback
            // is the right answer at startup but not here — a live session keeps the
            // effective map it is already running (ADR 0041 §3).
            if (loaded.map) |m| engine.action_map.free(self.gpa, m);
            return;
        }
        if (self.map) |old| engine.action_map.free(self.gpa, old);
        self.map = loaded.map;
        try out.print("mana: input reloaded — {d} actions bound\n", .{if (self.map) |m| m.bindings.len else 0});
        try out.flush();
    }
};

/// One `--play` poll of the rebinding-persistence driver (ADR 0041 §4, issue #238):
/// write the override file if the package script accepted a rebind since the last poll,
/// and report what happened on `out`.
///
/// **Nothing here is fatal to the session, but a failed save loses the rebind.** The
/// file *is* the channel: the live map only swaps when the watcher below detects the
/// override changing (ADR 0041 §4.3 — persist and apply are one motion), so if the write
/// fails there is no change to detect, no swap, and the rebind neither persists nor
/// applies. The session plays on with the bindings it already had, and the next rebind
/// retries. The most likely failure is `FileNotFound`, a package with no `save/`
/// directory (the engine creates none, and only `games/menu` ships one today; #240 moves
/// this path to the OS config dir). `OutOfMemory` is a real resource failure, not a
/// content error, so it alone propagates — the same benign case / `else => return err`
/// split `loadEffectiveActionMap` uses.
///
/// A `.unchanged` poll — the steady state, every poll of every session that never
/// rebinds — logs nothing, writes nothing, and allocates nothing.
fn persistBindings(
    out: *Io.Writer,
    io: Io,
    gpa: Allocator,
    path: []const u8,
    writer: *engine.input_override.OverrideWriter,
    rt: *engine.script_runtime.Runtime,
) !void {
    const outcome = writer.poll(gpa, io, Io.Dir.cwd(), path, rt) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try out.print(
                "mana: could not save bindings to '{s}' ({s}) — this rebind was neither saved nor applied\n",
                .{ path, @errorName(err) },
            );
            try out.flush();
            return;
        },
    };
    switch (outcome) {
        .unchanged => return,
        .written => |n| try out.print("mana: bindings saved to '{s}' — {d} action(s) overridden\n", .{ path, n }),
        // The driver could not express what the script proposed (an unknown source, an
        // action name that is not a ZON identifier), so it wrote nothing at all rather
        // than a file the loader could only reject. No write ⇒ no swap either, same as
        // the failed-save branch above — the current bindings stand.
        .rejected => |reason| try out.print(
            "mana: rebind rejected ({s}) — '{s}' not written; neither saved nor applied, keeping the current bindings\n",
            .{ @tagName(reason), path },
        ),
    }
    try out.flush();
}

/// Hand the package script the user override that is actually on disk (ADR 0041 §4
/// amendment, issue #247) — the read-back half of the persistence seam, called at script
/// init and again after every successful reload so what the script holds never diverges
/// from what the file says.
///
/// **Why the engine must do this.** The script cannot read the override itself (ADR 0003
/// §7 leaves it no filesystem), yet its `bindings` field is the WHOLE override the driver
/// writes back. Un-seeded, session 2's first rebind writes a file listing only that
/// rebind and silently drops session 1's — and the script's own duplicate check validates
/// against its shipped defaults instead of what is live.
///
/// **Re-seeding on reload is deliberate.** After a reload the file has changed: either
/// the driver wrote it (the seed is then a no-op re-derivation of what the script already
/// held) or a human hand-edited it, in which case the script's set is now stale and its
/// next write would clobber the edit. Re-reading is what makes the file, not the process,
/// the source of truth (invariant #1). It cannot feed back into the watcher: the seed
/// never bumps `revision_field`, so it provokes no write. **Scope of that promise:** it
/// holds for the entries the script's field can represent. A hand edit *outside* that
/// domain cannot be seeded at all, so re-seeding does not — and cannot — protect it from
/// the next write; it is reported instead (below), never silently dropped.
///
/// Best-effort, exactly like the override half of `loadEffectiveActionMap`: an absent
/// file seeds the empty set (the honest answer — the player has rebound nothing), and a
/// malformed one leaves the script's current set alone (last-good-wins, ADR 0041 §3;
/// `loadEffectiveActionMap` already logged why the map fell back). An entry the script's
/// one-source-per-action field cannot hold is logged to `out` (`logUnseedable`) — the
/// same benign-diagnostic treatment `logOverrideFallback` gives a rejected override, and
/// the point of #247: a loss the player cannot see is the bug. Errors:
/// `error.OutOfMemory` only — every content-shaped failure is handled here.
fn syncScriptBindings(out: *Io.Writer, io: Io, gpa: Allocator, path: []const u8, rt: *engine.script_runtime.Runtime) !void {
    const src = Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // No override (the common case — only `games/menu` ships a `save/` at all), or
        // an unreadable one: either way the script is told "nothing is overridden". An
        // empty map has nothing to skip, so there is nothing to report.
        else => {
            _ = try engine.input_override.seedBindings(gpa, rt, .{});
            return;
        },
    };
    defer gpa.free(src);

    const override = engine.action_map.parse(gpa, src) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Malformed: the effective map kept its last-good value, so the script's bindings
        // must keep theirs too — seeding an empty set here would tell it the player's
        // rebinds are gone and invite the next write to make that true.
        error.ParseZon, error.Unbound, error.WrongTypedSource => return,
    };
    defer engine.action_map.free(gpa, override);

    const seed = try engine.input_override.seedBindings(gpa, rt, override);
    defer gpa.free(seed.skipped); // the names borrow `override`; only the slice is ours
    for (seed.skipped) |action| try logUnseedable(out, path, action);
}

/// Log a binding the script's `bindings` field cannot represent (ADR 0041 §4 amendment):
/// it is live in the effective map — the merge is not lossy — but the script never sees
/// it, so the next rebind's whole-override write will drop it. Named for the player, who
/// hand-edited it and is the only one who can rewrite it in a shape that survives.
fn logUnseedable(out: *Io.Writer, path: []const u8, action: []const u8) !void {
    try out.print(
        "mana: override '{s}': '{s}' binds more than one source (or an analog one), which the remap UI cannot express — it applies now, but the next rebind will drop it\n",
        .{ path, action },
    );
    try out.flush();
}

/// Log a benign user-override fallback (ADR 0041 §3): the override at `path` was
/// `reason` (`err`), so the runner keeps the package-only map. Factored out so the
/// two fallback sites in `loadEffectiveActionMap` share one message shape.
fn logOverrideFallback(out: *Io.Writer, path: []const u8, reason: []const u8, err: anyerror) !void {
    try out.print("mana: override '{s}' {s} ({s}) — ignoring, using package input only\n", .{ path, reason, @errorName(err) });
    try out.flush();
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
        const quads = try engine.render.project(gpa, &world, view, &engine.render.default_palette, null);
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

/// Bundled HUD render state (issue #133; ADR 0034): a package's parsed `ui.Screen` plus
/// the font-glyph atlas merged into the scene atlas, so ONE bound texture carries both game
/// sprites and HUD label glyphs (`gpu.captureFrame`/`renderFrame` bind a single atlas).
/// Empty (`screen == null`) when the manifest declares no `hud` — the HUD is then a no-op.
/// Owns the screen and both atlases; `deinit`.
const HudState = struct {
    gpa: Allocator,
    screen: ?engine.ui.Screen = null,
    font: ?engine.sprite.Atlas = null,
    merged: ?engine.sprite.Atlas = null,

    /// The atlas BOTH game sprites and HUD glyphs render through: the font-merged atlas
    /// when a HUD is present, else the untouched scene `scene_atlas`.
    fn atlas(self: *HudState, scene_atlas: *const engine.sprite.Atlas) *const engine.sprite.Atlas {
        return if (self.merged) |*m| m else scene_atlas;
    }

    fn deinit(self: *HudState) void {
        if (self.merged) |*m| m.deinit();
        if (self.font) |*f| f.deinit();
        if (self.screen) |s| engine.ui.free(self.gpa, s);
    }
};

/// Load a package's HUD screen (issue #133) and merge the font glyph atlas into
/// `scene_atlas`, so a single bound texture carries game sprites and label glyphs. Returns
/// an empty `HudState` when the manifest declares no `hud` (genre-neutral: the engine draws
/// only what the package declares). `scene_atlas` — and whatever backs its region `ref`s
/// (the sheet store) — must outlive the returned state, whose merged atlas borrows those
/// refs. Caller `deinit`s. Errors: file read / `ui.parse` errors, `error.OutOfMemory`.
fn loadHud(io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest, scene_atlas: *const engine.sprite.Atlas) !HudState {
    const hud_rel = manifest.hud orelse return .{ .gpa = gpa };
    const hud_path = try std.fs.path.join(gpa, &.{ pkg, hud_rel });
    defer gpa.free(hud_path);
    const src = try Io.Dir.cwd().readFileAllocOptions(io, hud_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const screen = try engine.ui.parse(gpa, src);
    errdefer engine.ui.free(gpa, screen);
    var font = try engine.text.buildFontAtlas(gpa);
    errdefer font.deinit();
    const merged = try engine.sprite.merge(gpa, scene_atlas, &font);
    return .{ .gpa = gpa, .screen = screen, .font = font, .merged = merged };
}

/// Project a loaded `hud` (if any) over the current frame into a `render_ui.DrawList`,
/// reading live state one-way through the host chain (issue #133, issue #248): a
/// `ui_host.ScriptHost` over `sim`'s handler table in front of `render_ui.worldHost` over
/// `sim.world`, so ONE installed host serves both a `bind` naming a numeric data component
/// (`score`) and one naming a script-owned string (`bindings.fire` — the player's live input
/// binding). Which of the two a name goes to is decided by the package's ZON alone; the
/// runner names no binding key. `null` when the package declares no HUD. The draw list
/// samples `render_atlas` (the font-merged one), so pass `hud.atlas(&scene_atlas)` as both
/// the sprite atlas and here. Caller owns the result (`deinit`). Errors: `error.OutOfMemory`.
fn projectHud(gpa: Allocator, hud: *HudState, sim: *engine.Sim, view: engine.render.View, render_atlas: *const engine.sprite.Atlas) !?engine.render_ui.DrawList {
    const screen = hud.screen orelse return null;
    // Scoped to this projection: the host's string copies outlive only the `project` call
    // that turns them into glyph quads, which is exactly how long a `.text` must live.
    var host: engine.ui_host.ScriptHost = .init(gpa, &sim.script_runtime, engine.render_ui.worldHost(&sim.world));
    defer host.deinit();
    var draw = try engine.render_ui.project(gpa, &screen, host.host(), view.width, view.height, render_atlas, .{});
    errdefer draw.deinit();
    // `ui.Host.value` cannot fail, so a resolve that ran out of memory latched instead of
    // erroring — surface it rather than silently drawing a label's stale static text.
    if (host.oomed()) return error.OutOfMemory;
    return draw;
}

/// Capture the `--play` textured-sprite composite to a PNG, headlessly (issue #122). This
/// is the deterministic, GPU-free analogue of `playLoop`'s render zone: it builds the same
/// `Sim` as `runOnce`/`playLoop` (standard systems + the #30 input system, so the load path
/// is identical), loads the scene's sheets and packs the atlas exactly like `--play`, then
/// advances `ticks` FIXED steps — advancing the cosmetic animation cursor by the fixed sim
/// dt each tick rather than wall-clock, so the captured Nth-tick frame is reproducible —
/// and composites the flat quads + textured sprites through `engine.gpu.captureFrame` (the
/// null backend's CPU textured rasterizer), writing the readback via the same PNG path as
/// `--render`. Unlike `--render` this needs **no GPU** (the null backend samples the atlas
/// on the CPU), so a broken sprite is caught in CI, not by a user playing `--play`. Like the
/// other headless modes, a Lua-driven game needs `-Denable-lua` for its scene handler to
/// spawn the sprited entities; without it the scene renders whatever entities exist up front.
fn runRenderPlayFrame(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, path: []const u8, ticks: u32) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    var protos = try loadPrototypes(io, gpa, pkg);
    defer protos.deinit();

    // Action-binding table (ADR 0040 §3; issue #216): parsed before the Sim and freed
    // after it (LIFO defers), so the `sim.action_map` borrow below never dangles —
    // exactly how the scene's `tilemap` is scoped. Null when the manifest has no `input`.
    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = protos.prototypes };
    try engine.scene.load(parsed, &sim.world);
    if (parsed.tilemap) |*tm| sim.tilemap = tm; // see runOnce: parsed outlives sim (LIFO defers)
    if (action_map_opt) |*am| sim.action_map = am; // #216: borrowed like tilemap (outlives sim)
    try loadPackageScript(io, gpa, pkg, manifest, &sim);
    // Seed the script with the override on disk, exactly as `playLoop` does (ADR 0041 §4
    // amendment, #247). `loadActionMap` above already merged that override into the map
    // this path RESOLVES through, so without this the two halves disagree: `fire` would
    // really be on D while a `bindings.fire`-bound label resolved nothing and fell back to
    // its shipped-default text — #248's lie, reappearing in the headless path (invariant
    // #1) alone. Both render paths seed identically; only the loop around them differs.
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);
    try syncScriptBindings(out, io, gpa, override_path, &sim.script_runtime);
    sim.enterScene(parsed.name);
    try sim.addSystem(engine.input.inputMoveSystem); // #30: same load path as --play
    try registerStandardSystems(&sim);

    // Sheets + atlas exactly as `--play` (ADR 0031 §4): union of live + prototype sprites.
    var sheets = try engine.sprite.loadForScene(gpa, io, Io.Dir.cwd(), pkg, &sim.world, sim.prototypes);
    defer sheets.deinit();
    var atlas = try engine.sprite.buildAtlas(gpa, &sheets);
    defer atlas.deinit();

    // HUD (issue #133): merge the font glyph atlas into the scene atlas so the single
    // atlas `captureFrame` binds carries BOTH game sprites and label glyphs. A package
    // with no `hud` yields an empty state and the scene atlas is used untouched.
    var hud = try loadHud(io, gpa, pkg, manifest, &atlas);
    defer hud.deinit();
    const render_atlas = hud.atlas(&atlas);

    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        try sim.tick();
        engine.sprite.advance(&sim.world, &sheets, core.time.default_dt);
        engine.tint.advance(&sim.world, core.time.default_dt);
    }

    const view: engine.render.View = .{ .width = svg_view_size, .height = svg_view_size, .projection = manifest.projection };
    const quads = try engine.render.project(gpa, &sim.world, view, &engine.render.default_palette, &sheets);
    defer gpa.free(quads);
    const sprites = try engine.render.projectSprites(gpa, &sim.world, view, &sheets, render_atlas);
    defer gpa.free(sprites);

    // Composite the data-bound HUD over the game frame in the SAME capture: project it
    // (reading live score/lives through the host chain), then concatenate its panel quads
    // and glyph sprites onto the game's before the single `captureFrame` call.
    var hud_draw = try projectHud(gpa, &hud, &sim, view, render_atlas);
    defer if (hud_draw) |*d| d.deinit();
    const hud_rects: []const engine.gpu.Quad = if (hud_draw) |d| d.rects else &.{};
    const hud_glyphs: []const engine.gpu.SpriteQuad = if (hud_draw) |d| d.glyphs else &.{};
    const all_quads = try std.mem.concat(gpa, engine.gpu.Quad, &.{ quads, hud_rects });
    defer gpa.free(all_quads);
    const all_sprites = try std.mem.concat(gpa, engine.gpu.SpriteQuad, &.{ sprites, hud_glyphs });
    defer gpa.free(all_sprites);

    const clear = [4]f32{ 0.09, 0.10, 0.14, 1.0 };
    const pixels = try engine.gpu.captureFrame(gpa, view.width, view.height, all_quads, all_sprites, render_atlas.pixels, render_atlas.width, render_atlas.height, clear);
    defer gpa.free(pixels);
    const bytes = try data.png.encode(gpa, view.width, view.height, pixels);
    defer gpa.free(bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    try out.print(
        "mana: captured '{s}' — {d} entities, {d} sprites, {d} ticks, {d}x{d} → {s}\n",
        .{ manifest.name, sim.world.count(), sprites.len, ticks, view.width, view.height, path },
    );
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
    const quads = try engine.render.project(gpa, &world, view, &engine.render.default_palette, null);
    defer gpa.free(quads);
    const svg = try engine.render_svg.toSvg(gpa, quads, view, engine.render_svg.default_background);
    defer gpa.free(svg);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = svg });
    try out.print("mana: rendered '{s}' — {d} entities, {d}x{d} → {s}\n", .{ manifest.name, world.count(), view.width, view.height, path });
    try out.flush();
}

/// Scrub a headless playthrough (ADR 0029): build a full `Sim` — the same load path as
/// `runOnce` (standard systems, package script, prototypes) — advance it fixed steps, and
/// write one SVG per tick to `dir/frame_NNNN.svg` (4-digit, zero-padded). Frame
/// `frame_0000.svg` is the state *after* the first tick (so `on_scene_enter`'s spawns are
/// already visible, matching `runOnce`'s "fires on the first tick" note). Lets a human
/// scrub ghosts nav-moving and pickups getting eaten entirely offscreen.
///
/// With no `trace_path` it free-runs `ticks` steps (no input). With a `trace_path` it
/// instead replays that scenario file's `input_trace` — the SAME data format and snapshot
/// builder the scenario referee uses (`engine.scenario`), keyboard AND injected gamepad
/// alike (ADR 0040 §5) — setting one deterministic `InputSnapshot` per tick before each
/// step, one SVG per tick, so a human SEES a controller-driven playthrough with no device
/// or display (issue #222; invariant #4). Frame count is then the trace's total tick span,
/// `ticks` is ignored. Assertions in the trace file, if any, are not evaluated here — this
/// is a visual scrub, not the referee (`--scenario` alone runs the referee).
fn runFilmstrip(out: *Io.Writer, io: Io, gpa: Allocator, pkg: []const u8, dir: []const u8, ticks: u32, trace_path: ?[]const u8) !void {
    const manifest = try loadManifest(io, gpa, pkg);
    defer manifest_mod.free(gpa, manifest);
    try checkScriptApi(out, manifest);

    const scene_path = try std.fs.path.join(gpa, &.{ pkg, manifest.entry_scene });
    defer gpa.free(scene_path);
    const scene_src = try Io.Dir.cwd().readFileAllocOptions(io, scene_path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(scene_src);
    const parsed = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, parsed);

    var protos = try loadPrototypes(io, gpa, pkg);
    defer protos.deinit();

    // Action-binding table (ADR 0040 §3; issue #216): parsed before the Sim and freed
    // after it (LIFO defers), so the `sim.action_map` borrow below never dangles —
    // exactly how the scene's `tilemap` is scoped. Null when the manifest has no `input`.
    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = protos.prototypes };
    try engine.scene.load(parsed, &sim.world);
    if (parsed.tilemap) |*tm| sim.tilemap = tm; // see runOnce: parsed outlives sim (LIFO defers)
    if (action_map_opt) |*am| sim.action_map = am; // #216: borrowed like tilemap (outlives sim)
    try loadPackageScript(io, gpa, pkg, manifest, &sim);
    sim.enterScene(parsed.name);
    try registerStandardSystems(&sim);

    try Io.Dir.cwd().createDirPath(io, dir);
    const view: engine.render.View = .{ .width = svg_view_size, .height = svg_view_size, .projection = manifest.projection };

    // Injected input trace (issue #222): when a scenario file is given, replay its
    // `input_trace` one snapshot per tick — `segmentSnapshot` builds the exact deterministic
    // `InputSnapshot` (keyboard + gamepad) the scenario referee builds, so a gamepad
    // LEFT-STICK trace drives the `move` action through the same resolver the live game uses,
    // no device needed. `setInput` runs *before* each `tick` so the tick sees the input.
    // Frame count = the trace's total tick span. An absent (or empty) trace free-runs `ticks`.
    var frame_count: u32 = 0;
    if (trace_path) |tp| {
        const trace_src = try Io.Dir.cwd().readFileAllocOptions(io, tp, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(trace_src);
        const scenario = try engine.scenario.parse(gpa, trace_src);
        defer engine.scenario.free(gpa, scenario);
        for (scenario.input_trace) |seg| {
            const snap = try engine.scenario.segmentSnapshot(seg);
            var s: u32 = 0;
            while (s < seg.ticks) : (s += 1) {
                sim.setInput(snap);
                try sim.tick();
                try writeFilmstripFrame(io, gpa, &sim.world, view, dir, frame_count);
                frame_count += 1;
            }
        }
    }
    if (frame_count == 0) { // no trace, or a trace with an empty input_trace: free-run.
        var t: u32 = 0;
        while (t < ticks) : (t += 1) {
            try sim.tick();
            try writeFilmstripFrame(io, gpa, &sim.world, view, dir, t);
            frame_count += 1;
        }
    }
    try out.print(
        "mana: filmstrip '{s}' — {d} frames, {d}x{d} → {s}{s}\n",
        .{ manifest.name, frame_count, view.width, view.height, dir, if (trace_path != null) " (input trace)" else "" },
    );
    try out.flush();
}

/// Project the current world to one filmstrip frame and write `dir/frame_NNNN.svg`
/// (4-digit, zero-padded `index`). Shared by both `runFilmstrip` branches (free-run and
/// trace replay). No GPU: an SVG is text (ADR 0029), so this works on the default null
/// build. Errors: projection/SVG/OOM and the file write.
fn writeFilmstripFrame(io: Io, gpa: Allocator, world: *engine.World, view: engine.render.View, dir: []const u8, index: u32) !void {
    const quads = try engine.render.project(gpa, world, view, &engine.render.default_palette, null);
    defer gpa.free(quads);
    const svg = try engine.render_svg.toSvg(gpa, quads, view, engine.render_svg.default_background);
    defer gpa.free(svg);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "frame_{d:0>4}.svg", .{index});
    const frame_path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(frame_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = frame_path, .data = svg });
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

    var protos = try loadPrototypes(io, gpa, pkg);
    defer protos.deinit();

    // Action-binding table (ADR 0040 §3; issue #216): parsed before the Sim and freed
    // after it (LIFO defers), so the `sim.action_map` borrow below never dangles —
    // exactly how the scene's `tilemap` is scoped. Null when the manifest has no `input`.
    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = protos.prototypes };
    try engine.scene.load(parsed, &sim.world);
    if (parsed.tilemap) |*tm| sim.tilemap = tm; // see runOnce: parsed outlives sim (LIFO defers)
    if (action_map_opt) |*am| sim.action_map = am; // #216: borrowed like tilemap (outlives sim)
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
/// input-translation system so keys drive gameplay), watches the package's two
/// action-binding files so a live remap applies without a restart (ADR 0041 §3) and
/// persists any rebind the package script accepted to the user-override file (ADR 0041
/// §4 — the engine owns the write; a script cannot touch the filesystem, ADR 0003 §7),
/// opens the window *before* the
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
    var protos = try loadPrototypes(io, gpa, pkg);
    defer protos.deinit();

    // Action-binding table (ADR 0040 §3; issue #216), owned by a reloadable state (ADR
    // 0041 §3; issue #237) declared before the Sim and torn down after it (LIFO defers),
    // so the `sim.action_map` borrow below never dangles — exactly how the scene's
    // `tilemap` is scoped. Null map when the package binds nothing.
    var action_map_state: ActionMapState = .init(gpa, try loadActionMap(out, io, gpa, pkg, manifest));
    defer action_map_state.deinit();

    // Watch ONLY the two files the action map is derived from (ADR 0041 §3): a live
    // remap must apply without restarting the session. `--play` reloads the bindings and
    // nothing else — scene/script hot reload in a windowed session is `--watch`'s job.
    var input_watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer input_watcher.deinit();
    try watchActionMapFiles(&input_watcher, io, gpa, pkg, manifest);

    // The one path the persistence driver writes and the load/watch paths read — the
    // same join `loadEffectiveActionMap` makes, so all three agree on which file the
    // player's bindings live in (ADR 0041 §2.1's accepted Option B).
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = protos.prototypes };
    try engine.scene.load(parsed, &sim.world);
    // Same tilemap borrow as the one-shot path (see runOnce): `parsed` outlives `sim`
    // (LIFO defers), so nav can path over the scene's grid; null ⇒ nav no-ops.
    if (parsed.tilemap) |*tm| sim.tilemap = tm;
    sim.action_map = action_map_state.borrow(); // #216: borrowed like tilemap (outlives sim)
    try loadPackageScript(io, gpa, pkg, manifest, &sim); // #51: package Lua handlers
    // Hand the freshly loaded script the override that is on disk (ADR 0041 §4 amendment,
    // #247) — it cannot read the file itself, and it owns the WHOLE override the driver
    // writes back, so an un-seeded script silently drops earlier sessions' rebinds.
    try syncScriptBindings(out, io, gpa, override_path, &sim.script_runtime);
    // Rebinding persistence (ADR 0041 §4; issue #238), constructed AFTER the seed so the
    // revision it reads is the one the on-disk file reflects (seeding never bumps it). A
    // package that proposes no bindings never writes.
    var override_writer: engine.input_override.OverrideWriter = .init(&sim.script_runtime);
    sim.enterScene(parsed.name); // #54/ADR 0017: fire on_scene_enter on the first tick
    try sim.addSystem(engine.input.inputMoveSystem); // #30: held keys → velocity (before nav)
    try registerStandardSystems(&sim);

    // Load the sprite sheets this scene could reference (issue #113 phase 2; ADR 0031
    // §2; phase 2b lifecycle fix): the DERIVED `.msf` artifacts under
    // `<pkg>/.../generated/` (built by `mise run assets`) for BOTH `sim.world`'s live
    // `Sprite` components AND `sim.prototypes`. The latter matters here — `enterScene`
    // above only QUEUES `on_scene_enter` to fire on the first `sim.tick()` in the loop
    // below, and it's that scene's Lua handler that spawns sprited entities (e.g. pac
    // and the ghosts via `mana.spawn` in `games/pacman/scripts/rules.lua`), so `sim.world` is
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

    // HUD (issue #133): merge the font glyph atlas into the scene atlas and upload the
    // MERGED sheet, so the single sampled texture carries both game sprites and label
    // glyphs (the render zone appends the HUD draw list to the sprite pass each frame). A
    // package with no `hud` leaves the scene atlas untouched.
    var hud = try loadHud(io, gpa, pkg, manifest, &atlas);
    defer hud.deinit();
    const render_atlas = hud.atlas(&atlas);

    // UI focus/activate input (ADR 0039 §3; issue #209): a package's `hud` screen
    // (ADR 0039 §6's "one active screen") also becomes `sim`'s active `UiInput`
    // screen, so arrow/enter presses polled below drive its focus nav / on_activate
    // through `Sim.tick` instead of always falling to gameplay's `on_key` — the same
    // seam `tests/menu_acceptance.zig` exercises headlessly, now reachable from a
    // real window. A package with no `hud` (`hud.screen == null`) leaves `sim.ui_input`
    // at its default (no active screen), so this is a no-op for every existing game.
    if (hud.screen) |*screen| {
        const size = window.size();
        sim.ui_input.setScreen(screen, .{ .x = 0, .y = 0, .w = @floatFromInt(size[0]), .h = @floatFromInt(size[1]) });
    }

    var sprite_pipeline = try dev.createTexturedPipeline(.rgba8_unorm);
    defer sprite_pipeline.deinit(&dev);
    var atlas_tex: ?engine.gpu.Texture = null;
    defer if (atlas_tex) |*t| t.deinit(&dev);
    if (render_atlas.width > 0) {
        var t = try dev.createTexture(.{
            .width = render_atlas.width,
            .height = render_atlas.height,
            .format = .rgba8_unorm,
            .usage = .{ .transfer_dst = true, .sampled = true },
        });
        errdefer t.deinit(&dev);
        try dev.uploadTexture(&t, render_atlas.pixels);
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
    // Wall-clock accumulator for the binding-file poll (ADR 0041 §3): `--watch`'s
    // `watch_poll_ms` cadence rather than every frame, so a 60 fps session does not
    // `stat` the two files 60 times a second. Cosmetic timing — the reload is an
    // external input applied at a tick boundary, never hashed (ADR 0005 §4).
    var watch_accum_s: f32 = 0;

    while (!window.shouldClose()) {
        // One Tracy frame boundary per loop iteration (ADR 0023), marked first so
        // every iteration — including the out-of-date `continue` below — counts.
        tracy.frameMark();
        {
            const z = tracy.zone(@src(), "poll");
            defer z.end();
            sim.setInput(window.poll());
            // Track a resized window: a plain field write (no allocation, no focus
            // reset — only `setScreen` above does that), so a live resize keeps the
            // UI's hit-test/focus-nav geometry correct without disturbing `Focus.current`.
            if (hud.screen != null) {
                const size = window.size();
                sim.ui_input.viewport = .{ .x = 0, .y = 0, .w = @floatFromInt(size[0]), .h = @floatFromInt(size[1]) };
            }
        }

        // Advance the sim by whole fixed steps for the real time elapsed since the last
        // frame (`.awake` = the monotonic clock). The step count is deterministic per
        // elapsed time; the remainder carries in the accumulator.
        const now = Io.Timestamp.now(io, .awake);
        const elapsed_s: f32 = @as(f32, @floatFromInt(prev.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        prev = now;
        const steps = ts.advance(elapsed_s);

        // Live binding reload (ADR 0041 §3), on a TICK BOUNDARY: the previous
        // iteration's steps are done and this iteration's have not started, so no
        // system can observe a half-swapped map. Re-borrow from the owner rather than
        // assume the load-time pointer still describes it — `reload` owns whether a map
        // is present. A rejected edit keeps the last-good map, so `sim` never loses its
        // bindings to a bad save. Nothing allocates unless a file actually changed.
        watch_accum_s += elapsed_s;
        if (watch_accum_s >= watch_poll_s) {
            watch_accum_s = 0;
            // Persist first (ADR 0041 §4), on the same tick boundary and cadence: the
            // write the driver may just have made is then exactly the change the
            // watcher below detects, so an accepted rebind is saved AND applied within
            // one iteration — "persists and applies in one motion" (§4.3). Ordering
            // them the other way would delay every rebind by a poll interval.
            {
                const z = tracy.zone(@src(), "input_persist");
                defer z.end();
                try persistBindings(out, io, gpa, override_path, &override_writer, &sim.script_runtime);
            }
            if (input_watcher.poll(io)) {
                const z = tracy.zone(@src(), "input_reload");
                defer z.end();
                try action_map_state.reload(out, io, pkg, manifest);
                sim.action_map = action_map_state.borrow();
                // Re-seed the script from the file the reload just read (ADR 0041 §4
                // amendment, #247): after OUR write it re-derives what the script already
                // holds, but after a hand-edit it is what stops the script's now-stale set
                // from clobbering that edit on the next rebind — for the entries the
                // script's field can represent; one it cannot is logged, not protected.
                // It bumps no revision, so this cannot feed back into the persist branch
                // above, which deliberately runs FIRST: the file is then always at least
                // as new as the script's set when this re-seed reads it.
                try syncScriptBindings(out, io, gpa, override_path, &sim.script_runtime);
            }
        }

        {
            const z = tracy.zone(@src(), "tick");
            defer z.end();
            for (0..steps) |_| try sim.tick();
        }

        // Cosmetic sprite animation advances by WALL-CLOCK elapsed time, never a sim
        // tick, so it stays out of `stateHash` (ADR 0031 §1; issue #113 item 3).
        engine.sprite.advance(&sim.world, &sheets, elapsed_s);
        // Cosmetic tint/blink cue advance (issue #128), same wall-clock discipline.
        engine.tint.advance(&sim.world, elapsed_s);

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
            const quads = try engine.render.project(fa, &sim.world, view, &engine.render.default_palette, &sheets);
            // Textured sprite quads (ADR 0031 §4): the current animation frame's atlas
            // sub-rect, tinted and rotated to face travel; drawn over the flat quads.
            const sprite_quads = try engine.render.projectSprites(fa, &sim.world, view, &sheets, render_atlas);
            // HUD (issue #133): project the data-bound screen over the frame (reading live
            // world AND script state through the host chain, issue #248) and append its
            // panels + glyphs to the two draw lists — one bound (merged) atlas, one
            // renderFrame call, no extra pass. The draw list is allocated from the frame
            // arena (freed at next reset), so it needs no explicit deinit.
            const hud_draw = try projectHud(fa, &hud, &sim, view, render_atlas);
            const hud_rects: []const engine.gpu.Quad = if (hud_draw) |d| d.rects else &.{};
            const hud_glyphs: []const engine.gpu.SpriteQuad = if (hud_draw) |d| d.glyphs else &.{};
            const all_quads = try std.mem.concat(fa, engine.gpu.Quad, &.{ quads, hud_rects });
            const all_sprites = try std.mem.concat(fa, engine.gpu.SpriteQuad, &.{ sprite_quads, hud_glyphs });
            const atlas_ptr: ?*engine.gpu.Texture = if (atlas_tex) |*t| t else null;
            try engine.gpu.renderFrame(fa, &dev, &pipeline, &sprite_pipeline, atlas_ptr, frame.target, all_quads, all_sprites, clear);
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
    var protos = try loadPrototypes(io, gpa, pkg);
    defer protos.deinit();

    // Action-binding table (ADR 0040 §3; issue #216): parsed before the Sim and freed
    // after it (LIFO defers), so the `sim.action_map` borrow below never dangles —
    // exactly how the scene's `tilemap` is scoped. Null when the manifest has no `input`.
    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = protos.prototypes };
    try engine.scene.load(parsed, &sim.world);
    // Point the sim at the scene's grid level (ADR 0026/0027), if any, so `navSystem`
    // can path over it. `parsed` outlives `sim` — its `defer scene.free` was registered
    // before `sim`'s `defer deinit`, and defers run LIFO, so the sim is torn down first
    // and this borrow never dangles. Null tilemap ⇒ nav no-ops (see registerStandardSystems).
    if (parsed.tilemap) |*tm| sim.tilemap = tm;
    if (action_map_opt) |*am| sim.action_map = am; // #216: borrowed like tilemap (outlives sim)
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

/// Register the package's watch set (ADR 0005; ADR 0038 §4/§5), replacing any previous
/// set: `game.zon`, the named HUD screen (if any), and every file the loader discovers
/// by globbing the conventional kind-directories — `scenes/*.zon`, `prototypes/*.zon`,
/// and `scripts/*.lua` — plus the two action-binding files (ADR 0041 §3). The set is
/// derived from the filesystem, not enumerated in the manifest, so a newly-added
/// content file is watched without a manifest edit (invariant #1). A missing
/// kind-directory is silently skipped.
fn syncWatchSet(watcher: *data.Watcher, io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !void {
    watcher.clear();
    try watchFile(watcher, io, gpa, pkg, "game.zon");
    if (manifest.hud) |hud| try watchFile(watcher, io, gpa, pkg, hud);
    try watchActionMapFiles(watcher, io, gpa, pkg, manifest);
    try watchDir(watcher, io, gpa, pkg, "scenes", ".zon");
    try watchDir(watcher, io, gpa, pkg, "prototypes", ".zon");
    try watchDir(watcher, io, gpa, pkg, "scripts", ".lua");
}

/// Add the two files the effective action map is derived from (ADR 0041 §3) to
/// `watcher`, reusing `watchFile`: the package `input.zon` (only when the manifest
/// declares one) and the user override at `action_override_rel`. The override is added
/// **whether or not it exists yet** — `Watcher.add` accepts a currently-missing path
/// and reports its later creation as a change, which is exactly the "the player just
/// rebound a key for the first time" case (phase 4, #238, writes that file).
///
/// Factored out of `syncWatchSet` because `playLoop` watches *only* these two files:
/// it reloads the action map and nothing else, so watching the scene/script set there
/// would report changes it cannot act on.
fn watchActionMapFiles(watcher: *data.Watcher, io: Io, gpa: Allocator, pkg: []const u8, manifest: Manifest) !void {
    if (manifest.input) |rel| try watchFile(watcher, io, gpa, pkg, rel);
    try watchFile(watcher, io, gpa, pkg, action_override_rel);
}

/// Add a single package-relative file (`<pkg>/<rel>`) to the watch set.
fn watchFile(watcher: *data.Watcher, io: Io, gpa: Allocator, pkg: []const u8, rel: []const u8) !void {
    const joined = try std.fs.path.join(gpa, &.{ pkg, rel });
    defer gpa.free(joined);
    try watcher.add(io, joined);
}

/// Add every regular file whose name ends in `ext` directly under `<pkg>/<subdir>` to
/// the watch set. A missing directory is silently skipped; order is irrelevant (each
/// file is polled independently). Feature-folder nesting is deferred (ADR 0038 §3):
/// no in-repo package nests content, so this globs one level.
fn watchDir(watcher: *data.Watcher, io: Io, gpa: Allocator, pkg: []const u8, subdir: []const u8, ext: []const u8) !void {
    const sub = try std.fs.path.join(gpa, &.{ pkg, subdir });
    defer gpa.free(sub);
    var dir = Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        const joined = try std.fs.path.join(gpa, &.{ sub, entry.name });
        defer gpa.free(joined);
        try watcher.add(io, joined);
    }
}

const testing = std.testing;

/// `std.testing.tmpDir` always roots its temp dir at `Io.Dir.cwd()/.zig-cache/tmp/<sub>`
/// (see `std.testing.tmpDir`'s own use of `Io.Dir.cwd()`) — the same base `watchDir`/
/// `watchFile` hardcode. So a package path built from `tmp.sub_path` resolves correctly
/// through them without needing to pass a `Io.Dir` parameter through the whole chain.
fn tmpPkgPath(gpa: Allocator, tmp: *const testing.TmpDir) ![]u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

/// True if some watched path ends with `suffix` (order-independent — directory
/// iteration order is not guaranteed).
fn watchSetHasSuffix(watcher: *const data.Watcher, suffix: []const u8) bool {
    for (watcher.entries.items) |e| {
        if (std.mem.endsWith(u8, e.path, suffix)) return true;
    }
    return false;
}

test "watch set: extension filter and missing-dir skip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.createDirPath(io, "scenes");
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/a.zon", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/notes.txt", .data = "ignore me" });

    var watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer watcher.deinit();

    // Only the .zon file matches the extension filter; the .txt file is skipped.
    try watchDir(&watcher, io, gpa, pkg, "scenes", ".zon");
    try testing.expectEqual(@as(usize, 1), watcher.watchedCount());
    try testing.expect(watchSetHasSuffix(&watcher, "scenes/a.zon"));
    try testing.expect(!watchSetHasSuffix(&watcher, "scenes/notes.txt"));

    // A kind-directory that doesn't exist at all is silently skipped: no error, no
    // addition to the watch set.
    try watchDir(&watcher, io, gpa, pkg, "prototypes", ".zon");
    try testing.expectEqual(@as(usize, 1), watcher.watchedCount());
}

test "watch set: syncWatchSet globs kind-directories plus manifest and hud" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{ .sub_path = "game.zon", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hud.zon", .data = "x" });

    try tmp.dir.createDirPath(io, "scenes");
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/a.zon", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/b.zon", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/readme.txt", .data = "ignored" });

    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/rules.lua", .data = "x" });

    // No `prototypes/` directory at all — exercises the missing-kind-dir skip inside
    // `syncWatchSet` itself, not just `watchDir` directly.

    const manifest: Manifest = .{
        .name = "t",
        .version = "0",
        .entry_scene = "scenes/a.zon",
        .hud = "hud.zon",
    };

    var watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer watcher.deinit();
    try syncWatchSet(&watcher, io, gpa, pkg, manifest);

    // game.zon + hud.zon + save/input.zon + 2 scenes + 1 script; prototypes/ (missing)
    // contributes 0; scenes/readme.txt is filtered by extension. The manifest declares
    // no `.input`, so only the override half of the binding pair is watched.
    try testing.expectEqual(@as(usize, 6), watcher.watchedCount());
    try testing.expect(watchSetHasSuffix(&watcher, "game.zon"));
    try testing.expect(watchSetHasSuffix(&watcher, "hud.zon"));
    try testing.expect(watchSetHasSuffix(&watcher, "scenes/a.zon"));
    try testing.expect(watchSetHasSuffix(&watcher, "scenes/b.zon"));
    try testing.expect(watchSetHasSuffix(&watcher, "scripts/rules.lua"));
    try testing.expect(!watchSetHasSuffix(&watcher, "scenes/readme.txt"));

    // `syncWatchSet` clears before re-adding (last-good re-sync is idempotent).
    try syncWatchSet(&watcher, io, gpa, pkg, manifest);
    try testing.expectEqual(@as(usize, 6), watcher.watchedCount());
}

test "watch set: both binding files are watched — the package input.zon and the (not-yet-existing) user override (ADR 0041 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
    });
    // Deliberately NO `save/input.zon`: the override must be watched before it exists,
    // so the first-ever rebind (which creates the file) registers as a change.
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var watcher = data.Watcher.init(gpa, Io.Dir.cwd());
    defer watcher.deinit();
    try watchActionMapFiles(&watcher, io, gpa, pkg, manifest);

    try testing.expectEqual(@as(usize, 2), watcher.watchedCount());
    try testing.expect(watchSetHasSuffix(&watcher, "input.zon"));
    try testing.expect(watchSetHasSuffix(&watcher, "save/input.zon"));

    // Creating the override is a change the watcher reports (the phase-4 write path).
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{ .sub_path = "save/input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
    });
    try testing.expect(watcher.poll(io));

    // A package with no `.input` watches only the override half.
    var bare = data.Watcher.init(gpa, Io.Dir.cwd());
    defer bare.deinit();
    try watchActionMapFiles(&bare, io, gpa, pkg, .{ .name = "t", .version = "0", .entry_scene = "s.zon" });
    try testing.expectEqual(@as(usize, 1), bare.watchedCount());
}

test "action map reload: a rewritten package input.zon swaps the live bindings, and the Sim borrow follows the swap (ADR 0041 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    var state: ActionMapState = .init(gpa, try loadActionMap(out, io, gpa, pkg, manifest));
    defer state.deinit();

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    sim.action_map = state.borrow();
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, sim.action_map.?.find("jump").?.keys);

    // The player (or an editor) rewrites the binding; the reload swaps it in.
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
    });
    try state.reload(out, io, pkg, manifest);
    sim.action_map = state.borrow();
    try testing.expectEqualSlices(engine.platform.Key, &.{.enter}, sim.action_map.?.find("jump").?.keys);
}

test "action map reload: bad parse keeps previous bindings (last-good-wins, never cleared, ADR 0005 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    var state: ActionMapState = .init(gpa, try loadActionMap(out, io, gpa, pkg, manifest));
    defer state.deinit();

    // A package file saved mid-edit (unterminated literal): the reload must keep the
    // running map rather than crash or clear the bindings.
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter}
    });
    try state.reload(out, io, pkg, manifest);
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, state.borrow().?.find("jump").?.keys);
    try testing.expect(std.mem.indexOf(u8, out_w.buffered(), "keeping last good bindings") != null);

    // A rejected *override* (an action the package never declares) is the other
    // last-good path: `loadEffectiveActionMap` would fall back to the package-only map
    // at startup, but a live session keeps the map it is already running.
    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.escape} } } }
    });
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{ .sub_path = "save/input.zon", .data =
        \\.{ .actions = .{ .crouch = .{ .type = .button, .keys = .{.a} } } }
    });
    try state.reload(out, io, pkg, manifest);
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, state.borrow().?.find("jump").?.keys);
}

test "action map reload: the override still merges over the package after a reload (ADR 0041 §2 + §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{ .sub_path = "input.zon", .data =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space} },
        \\        .pause = .{ .type = .button, .keys = .{.escape} },
        \\    },
        \\}
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    var state: ActionMapState = .init(gpa, try loadActionMap(out, io, gpa, pkg, manifest));
    defer state.deinit();
    try testing.expect(state.borrow() != null); // package-only to start: no override yet

    // The rebind lands as a freshly-written override (what phase 4, #238, will write).
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{ .sub_path = "save/input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
    });
    try state.reload(out, io, pkg, manifest);

    const effective = state.borrow().?;
    try testing.expectEqualSlices(engine.platform.Key, &.{.enter}, effective.find("jump").?.keys); // override-wins
    try testing.expectEqualSlices(engine.platform.Key, &.{.escape}, effective.find("pause").?.keys); // unlisted ⇒ package default
}

test "action map reload: an override naming actions a package never declares is rejected — the unbound map is kept, not replaced (ADR 0041 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    // No `.input` in the manifest and no override on disk ⇒ nothing bound at load.
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    var state: ActionMapState = .init(gpa, try loadActionMap(out, io, gpa, pkg, manifest));
    defer state.deinit();
    try testing.expect(state.borrow() == null);

    // An override for a package that declares no actions merges over an EMPTY package
    // map, so every action it names is unknown — rejected, and the null map is kept.
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{ .sub_path = "save/input.zon", .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
    });
    try state.reload(out, io, pkg, manifest);
    try testing.expect(state.borrow() == null);
    try testing.expect(std.mem.indexOf(u8, out_w.buffered(), "rejected") != null);
}

test "load path: a manifest with `.input` loads and borrows a populated Sim.action_map (ADR 0040 §3, #216)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{
        .sub_path = "input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
        ,
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    // The same load helper the five run paths call, then the same borrow onto a Sim.
    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);
    try testing.expect(action_map_opt != null);

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    if (action_map_opt) |*am| sim.action_map = am;

    try testing.expect(sim.action_map != null);
    const jump = sim.action_map.?.find("jump").?;
    try testing.expectEqual(engine.action_map.ActionType.button, jump.type);
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, jump.keys);
}

test "load path: a manifest with no `.input` leaves Sim.action_map null (#216)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);
    try testing.expect(action_map_opt == null); // no `.input` ⇒ nothing loaded, Sim.action_map stays default null
}

test "load path: a present `save/input.zon` override merges over the package map (ADR 0041 §2, #236)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{
        .sub_path = "input.zon",
        .data =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space} },
        \\        .pause = .{ .type = .button, .keys = .{.escape} },
        \\    },
        \\}
        ,
    });
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{
        .sub_path = "save/input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
        ,
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);
    try testing.expect(action_map_opt != null);
    const effective = action_map_opt.?;

    const jump = effective.find("jump").?;
    try testing.expectEqualSlices(engine.platform.Key, &.{.enter}, jump.keys); // override-wins, replaced wholesale
    const pause = effective.find("pause").?;
    try testing.expectEqualSlices(engine.platform.Key, &.{.escape}, pause.keys); // unlisted ⇒ package default
}

test "play path: syncScriptBindings hands the script the override on disk, so a later whole-override write keeps it (#247)" {
    // The `playLoop` seam, driven directly (that loop is comptime-gated behind
    // -Denable-sdl3 -Denable-vulkan, so this is where its logic is provable headlessly).
    if (engine.script_api_version == 0) return error.SkipZigTest; // no handler table to seed
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{
        .sub_path = "save/input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
        ,
    });
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);

    var rt: engine.script_runtime.Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, "return { bindings = {}, bindings_revision = 0 }");

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    try syncScriptBindings(&out_w, io, gpa, override_path, &rt);
    try testing.expectEqualStrings("", out_w.buffered()); // a clean seed says nothing
    const pairs = (try rt.handlerFieldStrMap(gpa, "bindings")).?;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, pairs);
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("jump", pairs[0].key);
    try testing.expectEqualStrings("enter", pairs[0].value); // the capture vocabulary
    // A seed is not a proposal: the driver still has nothing to write.
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("bindings_revision").?);
}

test "play path: syncScriptBindings seeds an EMPTY set when no override exists, and leaves the script's set alone when one is malformed" {
    if (engine.script_api_version == 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);

    var rt: engine.script_runtime.Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, "return { bindings = { jump = \"enter\" } }");

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);

    // No `save/` at all — every package but `games/menu` today. "Nothing is overridden"
    // is the honest seed, and it must not error.
    try syncScriptBindings(&out_w, io, gpa, override_path, &rt);
    const cleared = (try rt.handlerFieldStrMap(gpa, "bindings")).?;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, cleared);
    try testing.expectEqual(@as(usize, 0), cleared.len);

    // A malformed override: last-good-wins (ADR 0041 §3) — the effective map kept its
    // bindings, so the script keeps its set rather than being told they are gone.
    try rt.loadHandlers(gpa, "return { bindings = { jump = \"enter\" } }");
    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{ .sub_path = "save/input.zon", .data = ".{ .actions = .{ .jump = " });
    try syncScriptBindings(&out_w, io, gpa, override_path, &rt);
    const kept = (try rt.handlerFieldStrMap(gpa, "bindings")).?;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("enter", kept[0].value);
}

test "play path: an override entry the script's field cannot hold is LOGGED, not silently dropped (#247)" {
    // The loss #247 is about was silent. This one is narrower — a hand-edited multi-source
    // binding, which the remap UI cannot produce — but silence is what made the original a
    // bug, so the runner names it. It still APPLIES (the merge is not lossy); what it will
    // not survive is the next rebind's whole-override write.
    if (engine.script_api_version == 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.createDirPath(io, "save");
    try tmp.dir.writeFile(io, .{
        .sub_path = "save/input.zon",
        .data =
        \\.{ .actions = .{
        \\    .jump = .{ .type = .button, .keys = .{.enter} },
        \\    .fire = .{ .type = .button, .keys = .{ .a, .s } },
        \\} }
        ,
    });
    const override_path = try std.fs.path.join(gpa, &.{ pkg, action_override_rel });
    defer gpa.free(override_path);

    var rt: engine.script_runtime.Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, "return { bindings = {}, bindings_revision = 0 }");

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    try syncScriptBindings(&out_w, io, gpa, override_path, &rt);

    const logged = out_w.buffered();
    try testing.expect(std.mem.indexOf(u8, logged, "fire") != null); // the action is NAMED
    try testing.expect(std.mem.indexOf(u8, logged, "drop") != null); // and the consequence
    try testing.expect(std.mem.indexOf(u8, logged, "jump") == null); // the seedable one is quiet

    // The representable entry still reached the script; only the other was skipped.
    const pairs = (try rt.handlerFieldStrMap(gpa, "bindings")).?;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, pairs);
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqualStrings("jump", pairs[0].key);
}

test "load path: a malformed `save/input.zon` override logs and falls back to the package-only map, not a crash (ADR 0041 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{
        .sub_path = "input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
        ,
    });
    try tmp.dir.createDirPath(io, "save");
    // An override naming an action the package never declares — a `merge` load error,
    // not a parse error, exercising the `error.UnknownAction` fallback branch.
    try tmp.dir.writeFile(io, .{
        .sub_path = "save/input.zon",
        .data =
        \\.{ .actions = .{ .crouch = .{ .type = .button, .keys = .{.a} } } }
        ,
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);
    try testing.expect(action_map_opt != null);
    const jump = action_map_opt.?.find("jump").?;
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, jump.keys); // package-only, override ignored
    try testing.expect(std.mem.indexOf(u8, out_w.buffered(), "rejected") != null); // logged, didn't crash
}

test "load path: a syntactically malformed `save/input.zon` override logs and falls back to the package-only map (ADR 0041 §3)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    try tmp.dir.writeFile(io, .{
        .sub_path = "input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }
        ,
    });
    try tmp.dir.createDirPath(io, "save");
    // Broken ZON syntax (unterminated struct literal) — hits the separate `parse`
    // fallback branch, distinct from the merge-rejection test above.
    try tmp.dir.writeFile(io, .{
        .sub_path = "save/input.zon",
        .data =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter}
        ,
    });
    const manifest: Manifest = .{ .name = "t", .version = "0", .entry_scene = "s.zon", .input = "input.zon" };

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    const out = &out_w;

    const action_map_opt = try loadActionMap(out, io, gpa, pkg, manifest);
    defer if (action_map_opt) |am| engine.action_map.free(gpa, am);
    try testing.expect(action_map_opt != null);
    const jump = action_map_opt.?.find("jump").?;
    try testing.expectEqualSlices(engine.platform.Key, &.{.space}, jump.keys); // package-only, override ignored
    try testing.expect(std.mem.indexOf(u8, out_w.buffered(), "failed to parse") != null); // logged, didn't crash
}

/// Count regular files ending in `ext` directly under `<pkg>/<subdir>` (test helper).
fn countFilesWithExt(io: Io, pkg: []const u8, subdir: []const u8, ext: []const u8, gpa: Allocator) !usize {
    const sub = try std.fs.path.join(gpa, &.{ pkg, subdir });
    defer gpa.free(sub);
    var dir = try Io.Dir.cwd().openDir(io, sub, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ext)) n += 1;
    }
    return n;
}

test "filmstrip: an injected gamepad+key trace drives one SVG frame per trace tick, headlessly (issue #222)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const pkg = try tmpPkgPath(gpa, &tmp);
    defer gpa.free(pkg);

    // A minimal, genre-neutral package: a manifest, a one-entity scene, and a trace file
    // that injects a LEFT-STICK push (`left_x`) then a key. No Lua, no tilemap — this pins
    // the trace-driving/render plumbing on the default null backend, not any game's rules.
    try tmp.dir.writeFile(io, .{ .sub_path = "game.zon", .data =
        \\.{ .name = "filmstrip_test", .version = "0", .entry_scene = "scenes/s.zon" }
    });
    try tmp.dir.createDirPath(io, "scenes");
    try tmp.dir.writeFile(io, .{ .sub_path = "scenes/s.zon", .data =
        \\.{ .name = "s", .entities = .{ .{ .name = "e", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } } } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "trace.zon", .data =
        \\.{ .input_trace = .{
        \\    .{ .ticks = 3, .pad_axes = .{ .{ .name = "left_x", .value = 1.0 } } },
        \\    .{ .ticks = 2, .keys = .{ "up" } },
        \\} }
    });

    const dir = try std.fs.path.join(gpa, &.{ pkg, "frames" });
    defer gpa.free(dir);
    const trace = try std.fs.path.join(gpa, &.{ pkg, "trace.zon" });
    defer gpa.free(trace);

    var out_buf: [512]u8 = undefined;
    var out_w = Io.Writer.fixed(&out_buf);
    // `ticks` (99) is deliberately NOT 5: a present trace governs the frame count, so this
    // proves the trace span — 3 + 2 = 5 ticks — wins over the free-run `--ticks`.
    try runFilmstrip(&out_w, io, gpa, pkg, dir, 99, trace);

    try testing.expectEqual(@as(usize, 5), try countFilesWithExt(io, pkg, "frames", ".svg", gpa));
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
        "mana: watching '{s}' — {d} files (manifest + globbed content); Ctrl-C to stop\n",
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

test "play path: projectHud resolves a script-bound label live, and still resolves a world-bound one (#248)" {
    // `projectHud` is the ONE host install point both render paths share (`playLoop`'s
    // render zone is comptime-gated behind -Denable-sdl3 -Denable-vulkan, so this is
    // where the chain is provable headlessly). It pins that the script host is actually
    // dispatched from the live path — not merely available — and that chaining it in
    // front of `worldHost` did not cost the numeric HUD binding it used to serve alone.
    if (engine.script_api_version == 0) return error.SkipZigTest; // no handler table to read
    const gpa = testing.allocator;

    // A HUD screen shaped like a package's: one label bound to a script handler field
    // (`bindings.fire`), one to a numeric world data component (`score`). Both keys come
    // from this ZON — the runner names neither.
    const screen = try engine.ui.parse(gpa,
        \\.{
        \\    .name = "hud",
        \\    .root = .{
        \\        .kind = .container,
        \\        .layout = .flex,
        \\        .direction = .column,
        \\        .children = .{
        \\            .{ .kind = .label, .width = 200, .height = 14, .bind = "bindings.fire", .text = "W" },
        \\            .{ .kind = .label, .width = 200, .height = 14, .bind = "score", .text = "0" },
        \\        },
        \\    },
        \\}
    );
    var hud: HudState = .{ .gpa = gpa, .screen = screen, .font = try engine.text.buildFontAtlas(gpa) };
    defer hud.deinit();

    var sim = engine.Sim.init(gpa, core.time.default_dt);
    defer sim.deinit();
    // The live script state a rebind would have produced (ADR 0041 §4's `bindings`), and
    // the live world state a HUD reads (ADR 0024).
    try sim.loadScript("return { bindings = { fire = \"pad_south\" } }");
    const player = try sim.world.spawn();
    try sim.world.setDataByName(player, "score", 1200);

    const view: engine.render.View = .{ .width = 256, .height = 64, .projection = .{ .orthographic = .{} } };
    var draw = (try projectHud(gpa, &hud, &sim, view, &hud.font.?)).?;
    defer draw.deinit();

    // "pad_south" (9 glyphs, the LIVE script value — not the 1-glyph static "W") plus
    // "1200" (4 glyphs, the live world value — not the 1-glyph static "0").
    try testing.expectEqual(@as(usize, 13), draw.glyphs.len);
}

test "runtime can import the engine" {
    try std.testing.expect(engine.ready);
}
