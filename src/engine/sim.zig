//! The fixed-timestep frame (ADR 0007 §1). `Sim` owns the world, an ordered list of
//! systems, a command buffer, an event queue, event handlers, and a `Timers` (the
//! engine-side backing for ADR 0003 §2 `mana.after`/`every`). `tick` runs the
//! deterministic frame: systems → flush commands → dispatch events → advance
//! timers. Registering a system or handler is the seam scripting and physics plug
//! into, so subsystems compose here instead of editing runtime orchestration.
//! Rendering is separate (render-side, ADR 0006).

const std = @import("std");
const core = @import("core");
const tracy = core.tracy;
const World = @import("world.zig").World;
const command = @import("command.zig");
const event = @import("event.zig");
const timer = @import("timer.zig");
const script_runtime = @import("script_runtime.zig");
const script = @import("script");
const platform = @import("platform");
const prototype = @import("prototype.zig");
const Tilemap = @import("tilemap.zig").Tilemap;
const ui_dispatch = @import("ui_dispatch.zig");

const Allocator = std.mem.Allocator;

/// What a system receives each tick. Systems read/iterate `world` and record
/// deferred changes into `commands` (using `gpa`); they may enqueue `events`.
/// `input` is this tick's `InputSnapshot` (ADR 0009 §3/§4: sampled once, immutable
/// for the whole tick — every system reads the same value) — set via `Sim.setInput`
/// before `tick`; defaults to an all-empty snapshot, so a `Sim` that never calls
/// `setInput` behaves exactly as before input delivery existed.
pub const Context = struct {
    world: *World,
    commands: *command.CommandBuffer,
    events: *event.Queue,
    gpa: Allocator,
    dt: f32,
    tick: u64,
    input: platform.InputSnapshot,
    /// The scene's grid level (ADR 0026/0027), or null if the sim has none. The `nav`
    /// steering system paths over it; every other system ignores it. Null for a sim
    /// that never sets `Sim.tilemap`, so nav no-ops and existing sims are unaffected.
    tilemap: ?*const Tilemap = null,
    /// Per-tick scratch allocator (issue #153): backed by `Sim.scratch_arena`, reset
    /// (capacity retained) once per tick before systems run. For system-local working
    /// memory that never survives past this tick's return — e.g. `collision`'s
    /// positioned bodies and spatial-hash — so a system needing per-tick scratch
    /// space never inits/deinits its own arena from `gpa` (CLAUDE.md: no per-frame
    /// heap alloc in the hot loop). Never for state read next tick; use `gpa` for
    /// anything that must outlive the tick.
    scratch: Allocator,
};

/// A system's own reported failure — the native-system analogue of a Lua handler
/// throwing inside `pcall` (ADR 0003 §9). Caught at the per-invocation transaction
/// boundary in `tick`: the commands that invocation queued are rolled back and the
/// sim continues to the next system. Distinct from `error.OutOfMemory`, which is
/// never a "content bug" — it always propagates and aborts the tick.
pub const SystemError = Allocator.Error || error{SystemFailed};

/// A system: a free function over a `Context`. Each invocation is a transaction
/// (ADR 0003 §9 / issue #2): if it returns `error.SystemFailed`, the commands it
/// queued this call are discarded (never applied) and the sim keeps running;
/// `error.OutOfMemory` propagates unconditionally.
pub const System = *const fn (*Context) SystemError!void;

/// An event handler: reacts to one dispatched event; may read/mutate the world
/// (dispatch runs after the command flush). Recording deferred changes is a
/// scripting-era extension.
pub const Handler = *const fn (world: *World, ev: event.Event) void;

/// Default seed for `Sim.rng` (ADR 0022): a fixed constant, not derived from the
/// scene/clock, so a `Sim` that never calls `setRngSeed` is still fully
/// deterministic and reproducible run-to-run. Threading a per-scene/manifest seed
/// through is a follow-up (no game needs it yet — CLAUDE.md "no speculative
/// flexibility").
pub const default_rng_seed: u64 = 0x6D616E615F726E67; // "mana_rng" in ASCII hex

pub const Sim = struct {
    gpa: Allocator,
    world: World,
    commands: command.CommandBuffer = .{},
    events: event.Queue = .{},
    systems: std.ArrayList(System) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    timers: timer.Timers = .{},
    /// This Sim's single script runtime (ADR 0003 §8: one Lua state per Sim). A
    /// comptime no-op unless `-Denable-lua`; starts idle until `loadScript`.
    script_runtime: script_runtime.Runtime = .{},
    /// Named entity prototypes `mana.spawn` resolves against (ADR 0016). Empty by
    /// default (every `spawn` misses); the runner populates it from package ZON. The
    /// registry borrows its prototype slice — the owner must outlive the `Sim`.
    prototypes: prototype.Registry = .{},
    /// A scene whose `on_scene_enter` (ADR 0017/0018) is due to fire on the next
    /// `tick`, or null. Set by `enterScene` when a scene becomes active; consumed and
    /// dispatched host-live at the start of that tick's dispatch phase. Borrows the
    /// name — the caller keeps it alive until the following `tick` (the runner holds
    /// the parsed scene for the Sim's lifetime).
    pending_scene: ?[]const u8 = null,
    /// The `InputSnapshot` the next `tick` exposes to systems via `Context.input`
    /// (ADR 0009 §3/§4), set by `setInput`. Defaults to an all-empty snapshot, so a
    /// `Sim` that never calls `setInput` — every existing caller today — ticks
    /// exactly as it did before input delivery existed.
    input: platform.InputSnapshot = .{},
    /// The scene's grid level (ADR 0026), borrowed for the `nav` steering system (ADR
    /// 0027) to path over. Null by default, so a sim that never sets it ticks exactly
    /// as before (nav no-ops). The runner points it at the loaded scene's tilemap; the
    /// borrowed `Tilemap` must outlive the `Sim` (the runner holds the parsed scene).
    tilemap: ?*const Tilemap = null,
    /// Last tick's input, diffed against `input` each tick to emit `on_key` edges
    /// (ADR 0021). Defaults empty, so a key held on the very first tick reads as a
    /// press. Not part of the state hash (input never is, ADR 0009).
    prev_input: platform.InputSnapshot = .{},
    /// The active UI screen's focus/dispatch state (ADR 0039; issue #209): `null`
    /// screen by default, so a `Sim` that never sets one behaves exactly as before
    /// this field existed — every key edge falls straight through to `on_key`. The
    /// runner (or a test) points this at a loaded `ui.Screen` via
    /// `ui_input.setScreen` — mirroring how `tilemap`/`prototypes` are populated —
    /// so `tick` can route keyboard focus-nav/activate edges into it (ADR 0039 §3:
    /// "UI consumes an input first; gameplay sees only what the UI did not claim").
    /// Cosmetic-adjacent and never hashed, same as the `ui`/`ui_dispatch` state it
    /// wraps (ADR 0039 §4).
    ui_input: ui_dispatch.UiInput = .{},
    dt: f32,
    tick_count: u64 = 0,
    /// The seeded stream `mana.random`/`random_int` draw from (ADR 0022, issue #47).
    /// Defaults to `default_rng_seed`, so an unseeded `Sim` is still deterministic;
    /// `setRngSeed` overrides it before the first draw (e.g. per-run reproducible
    /// seeds). Advancing it is the *only* effect `mana.random`/`random_int` have —
    /// they never touch `world`/`commands`, so they need no command-buffer entry.
    rng: core.Rng = core.Rng.init(default_rng_seed),
    /// Backing store for `Context.scratch` (issue #153): one arena reused every tick
    /// via `reset(.retain_capacity)` in `tick`, instead of a system `init`/`deinit`ing
    /// its own arena from `gpa` each call — the sanctioned reusable-arena pattern
    /// `runtime.playLoop`'s `frame_arena` already uses for render scratch. Owned by
    /// `Sim`, freed exactly once in `deinit`.
    scratch_arena: std.heap.ArenaAllocator,

    /// A sim with an empty world at fixed step `dt`. Populate `world` (e.g. via
    /// `engine.scene.load`) and register systems, then `run`/`tick`.
    pub fn init(gpa: Allocator, dt: f32) Sim {
        return .{ .gpa = gpa, .world = World.init(gpa), .dt = dt, .scratch_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Sim) void {
        self.script_runtime.deinit(self.gpa);
        self.systems.deinit(self.gpa);
        self.handlers.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.commands.deinit(self.gpa);
        self.timers.deinit(self.gpa);
        self.scratch_arena.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    /// Load `source` as this Sim's single event-handler table (ADR 0003 §1). The
    /// runtime dispatches `spawned`/`collision_begin` events to its matching keys
    /// each `tick`. Under a default (no-`-Denable-lua`) build this is a no-op.
    /// `source` is a NUL-terminated Lua chunk, borrowed only for the call. Errors
    /// propagate from loading/running the module (bad Lua, a non-table return, or
    /// allocation failure).
    pub fn loadScript(self: *Sim, source: [:0]const u8) !void {
        try self.script_runtime.loadHandlers(self.gpa, source);
    }

    /// Mark `scene_name` as newly active, so its `on_scene_enter` (ADR 0017/0018)
    /// fires on the next `tick` with the host live — the hook a script uses to query
    /// its entities and wire timers/rules. The runner calls this after loading the
    /// entry scene; future scene switching calls it per transition. `scene_name` must
    /// stay alive until the following `tick`. A no-op-yielding null if never called.
    pub fn enterScene(self: *Sim, scene_name: []const u8) void {
        self.pending_scene = scene_name;
    }

    /// Register a system; systems run each tick in registration order.
    pub fn addSystem(self: *Sim, system: System) Allocator.Error!void {
        try self.systems.append(self.gpa, system);
    }

    /// Register an event handler; handlers see every dispatched event in order.
    pub fn addHandler(self: *Sim, handler: Handler) Allocator.Error!void {
        try self.handlers.append(self.gpa, handler);
    }

    /// Schedule `cb` to fire once, `delay_seconds` of sim time from now (ADR 0003
    /// §2 `mana.after`). Fired at the end of `tick`, after event dispatch.
    pub fn after(self: *Sim, delay_seconds: f32, cb: *const fn (*World) void) Allocator.Error!timer.Handle {
        return self.timers.after(self.gpa, delay_seconds, .{ .native = cb });
    }

    /// Schedule `cb` to fire every `interval_seconds` of sim time (ADR 0003 §2
    /// `mana.every`). Fired at the end of `tick`, after event dispatch.
    pub fn every(self: *Sim, interval_seconds: f32, cb: *const fn (*World) void) Allocator.Error!timer.Handle {
        return self.timers.every(self.gpa, interval_seconds, .{ .native = cb });
    }

    /// Cancel a timer scheduled via `after`/`every`; a stale handle is a no-op.
    pub fn cancel(self: *Sim, handle: timer.Handle) void {
        self.timers.cancel(handle);
    }

    /// Set the `InputSnapshot` the *next* `tick` exposes to systems via
    /// `Context.input` (ADR 0009 §3/§4). Call once per tick, before `tick()` — e.g.
    /// from `platform.Window.poll` once the interactive loop lands, or by replaying
    /// a recorded `[]InputSnapshot` trace one entry per tick for deterministic,
    /// bit-identical input replay. Overwrites whatever was set before; if never
    /// called, `tick` sees the all-empty default snapshot.
    pub fn setInput(self: *Sim, snapshot: platform.InputSnapshot) void {
        self.input = snapshot;
    }

    /// Re-seed `mana.random`/`random_int`'s stream (ADR 0022). Call before the
    /// first script dispatch that draws from it; a `Sim` that never calls this uses
    /// `default_rng_seed`. Two sims seeded identically (and driven by identical
    /// inputs) draw an identical sequence — the determinism contract this exists for.
    pub fn setRngSeed(self: *Sim, seed: u64) void {
        self.rng = core.Rng.init(seed);
    }

    /// Advance one fixed step: run systems (each its own rollback transaction),
    /// flush deferred commands (emitting lifecycle events), dispatch all events,
    /// advance timers (firing any now due), then increment the tick counter.
    ///
    /// Timers fire *after* event dispatch: by then no system is mid-iteration and
    /// the world reflects every structural change queued this tick, so a timer
    /// callback can mutate it directly (like an event `Handler`) without needing
    /// the command buffer. A timer's own effects become visible starting next tick,
    /// consistent with how flushed spawns/despawns land before the next tick reads
    /// them.
    pub fn tick(self: *Sim) !void {
        // Retain capacity, drop contents: `Context.scratch` starts each tick empty
        // but never re-syscalls for memory a prior tick already grew it to (issue
        // #153) — no per-frame heap alloc in the hot loop.
        _ = self.scratch_arena.reset(.retain_capacity);
        var ctx: Context = .{
            .world = &self.world,
            .commands = &self.commands,
            .events = &self.events,
            .gpa = self.gpa,
            .dt = self.dt,
            .tick = self.tick_count,
            .input = self.input,
            .tilemap = self.tilemap,
            .scratch = self.scratch_arena.allocator(),
        };
        {
            const z = tracy.zone(@src(), "sim.systems");
            defer z.end();
            for (self.systems.items) |system| {
                // ADR 0003 §9 / issue #2: each system invocation is a transaction. Mark
                // the buffer first; on `error.SystemFailed`, roll back to the mark so
                // none of this call's commands ever reach flush, and keep ticking.
                // `error.OutOfMemory` is not a content bug — it propagates and aborts.
                const mark = self.commands.mark();
                system(&ctx) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.SystemFailed => try self.commands.rollback(&self.world, mark),
                };
            }
        }
        {
            const z = tracy.zone(@src(), "sim.flush");
            defer z.end();
            try self.commands.flush(self.gpa, &self.world, &self.events);
        }
        // Sim time exposed to script `mana.now` this dispatch (ADR 0003 §2 / ADR
        // 0015): tick-derived seconds elapsed at the start of this tick, so it is
        // deterministic and never reads a wall clock.
        const now_seconds: f64 = @as(f64, @floatFromInt(self.tick_count)) * @as(f64, self.dt);
        // The live world, command buffer, `now`, and prototype registry back the ADR
        // 0015 host seam for a handler's `mana` reads and deferred mutations (applied
        // at next tick's flush). All script dispatch below is a comptime no-op — zero
        // cost, sim bit-identical — unless `-Denable-lua`; handler errors are caught
        // and their queued mutations rolled back (§9); only OOM propagates.
        const dc: script_runtime.DispatchCtx = .{
            .world = &self.world,
            .commands = &self.commands,
            .gpa = self.gpa,
            .now_seconds = now_seconds,
            .prototypes = self.prototypes,
            .timers = &self.timers,
            .rng = &self.rng,
            .tilemap = self.tilemap,
            .input = self.input,
        };
        // The dispatch phase is bounded by one Tracy zone: this is the ADR 0003 §6
        // per-frame script-dispatch budget site (the fine per-handler `script.*`
        // zones in `script_runtime` nest inside it). Native handlers run here too but
        // are cheap; script cost dominates once `-Denable-lua` is on.
        {
            const z = tracy.zone(@src(), "sim.dispatch");
            defer z.end();
            // A newly-active scene bootstraps first (ADR 0017/0018): its `on_scene_enter`
            // runs host-live before this tick's other events, so a script can query the
            // freshly-loaded scene and wire its timers/rules.
            if (self.pending_scene) |scene_name| {
                self.pending_scene = null;
                try self.script_runtime.dispatchSceneEnter(scene_name, dc);
            }
            // Keyboard edges (ADR 0021, ordered per ADR 0039 §3): for every key whose
            // held-state changed since last tick, in Key-enum order (deterministic),
            // the active UI screen (if any) gets first refusal — a focus-nav/activate
            // press edge it claims fires on_focus/on_activate instead of on_key, and
            // never reaches gameplay. Only an edge the UI does not claim (no screen
            // active, a release edge, or a key with no UI meaning) dispatches on_key,
            // host-live and before timers, exactly as before this field existed. The
            // temporary screen layout `ui_input.keyEdge` needs is scratch-arena backed
            // (issue #153: no per-frame heap alloc in the hot loop).
            inline for (comptime std.enums.values(platform.Key)) |k| {
                const now_held = self.input.keys.contains(k);
                if (now_held != self.prev_input.keys.contains(k)) {
                    const ui_consumed = try self.ui_input.keyEdge(ctx.scratch, &self.script_runtime, dc, k, now_held);
                    if (!ui_consumed) {
                        try self.script_runtime.dispatchKey(@tagName(k), now_held, dc);
                    }
                }
            }
            self.prev_input = self.input;
            for (self.events.items()) |ev| {
                for (self.handlers.items) |handler| handler(&self.world, ev);
                try self.script_runtime.dispatch(ev, dc);
            }
            self.events.clear();
        }
        {
            // Advance timers with the host installed (ADR 0019), so Lua timer callbacks
            // fire host-live; native timers are unaffected. Only OOM propagates.
            const z = tracy.zone(@src(), "sim.timers");
            defer z.end();
            try self.script_runtime.advanceTimers(dc, self.dt);
        }
        self.tick_count += 1;
    }

    /// Advance `steps` fixed steps.
    pub fn run(self: *Sim, steps: u32) !void {
        for (0..steps) |_| try self.tick();
    }

    /// Determinism fingerprint (delegates to the world's state hash).
    pub fn stateHash(self: *Sim) u64 {
        return self.world.stateHash();
    }
};

const testing = std.testing;
const ui = @import("ui");

test "sim: a system recording a despawn takes effect next flush and dispatches an event" {
    const Counter = struct {
        var despawns: u32 = 0;
        var did_despawn: bool = false;
        fn system(ctx: *Context) SystemError!void {
            // Despawn the first entity exactly once.
            if (!did_despawn) {
                if (ctx.world.transforms.entities().len > 0) {
                    const idx = ctx.world.transforms.entities()[0];
                    try ctx.commands.despawn(ctx.gpa, .{ .index = idx, .generation = 0 });
                    did_despawn = true;
                }
            }
        }
        fn handler(_: *World, ev: event.Event) void {
            if (ev == .despawned) despawns += 1;
        }
    };
    Counter.despawns = 0;
    Counter.did_despawn = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.addSystem(Counter.system);
    try sim.addHandler(Counter.handler);

    try testing.expectEqual(@as(usize, 1), sim.world.count());
    try sim.tick();
    try testing.expectEqual(@as(usize, 0), sim.world.count()); // despawn applied at flush
    try testing.expectEqual(@as(u32, 1), Counter.despawns); // dispatched
}

test "sim: an erroring system's queued commands are discarded and the sim keeps running" {
    const Flaky = struct {
        var later_system_ran: bool = false;

        // Queues a despawn, then fails: the despawn must never reach the world.
        fn failing(ctx: *Context) SystemError!void {
            if (ctx.world.transforms.entities().len > 0) {
                const idx = ctx.world.transforms.entities()[0];
                try ctx.commands.despawn(ctx.gpa, ctx.world.entityAt(idx));
            }
            return error.SystemFailed;
        }
        fn after(_: *Context) SystemError!void {
            later_system_ran = true;
        }
    };
    Flaky.later_system_ran = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.addSystem(Flaky.failing);
    try sim.addSystem(Flaky.after);

    try sim.tick(); // must not propagate error.SystemFailed
    try testing.expect(sim.world.isValid(e)); // rolled back: despawn never applied
    try testing.expect(Flaky.later_system_ran); // sim kept running to the next system
    try testing.expectEqual(@as(u64, 1), sim.tick_count); // tick completed normally
}

test "sim: a timer scheduled via after fires on the tick it becomes due, not before" {
    const Counter = struct {
        var fires: u32 = 0;
        fn cb(_: *World) void {
            fires += 1;
        }
    };
    Counter.fires = 0;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0); // dt = 1/60
    defer sim.deinit();
    _ = try sim.after(2.0 / 60.0, Counter.cb); // due exactly at tick 2

    try sim.tick(); // tick 1: now = 1/60, not due
    try testing.expectEqual(@as(u32, 0), Counter.fires);
    try sim.tick(); // tick 2: now = 2/60, due -> fires
    try testing.expectEqual(@as(u32, 1), Counter.fires);
    try sim.tick(); // one-shot: no further fires
    try testing.expectEqual(@as(u32, 1), Counter.fires);
}

test "sim: a timer scheduled via every re-fires each tick through repeated Sim.tick calls" {
    const Counter = struct {
        var fires: u32 = 0;
        fn cb(_: *World) void {
            fires += 1;
        }
    };
    Counter.fires = 0;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    _ = try sim.every(1.0 / 60.0, Counter.cb); // once per tick

    try sim.run(5);
    try testing.expectEqual(@as(u32, 5), Counter.fires);
}

test "sim: cancelling a timer before it is due stops it from firing through tick" {
    const Counter = struct {
        var fires: u32 = 0;
        fn cb(_: *World) void {
            fires += 1;
        }
    };
    Counter.fires = 0;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    const h = try sim.after(5.0 / 60.0, Counter.cb);
    try sim.tick();
    sim.cancel(h);
    try sim.run(10);
    try testing.expectEqual(@as(u32, 0), Counter.fires);
}

test "sim: a tick with no scheduled timers does not perturb the world's state hash" {
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    try sim.addSystem(@import("systems.zig").movementSystem);

    var reference = World.init(testing.allocator);
    defer reference.deinit();
    const re = try reference.spawn();
    try reference.setTransform(re, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });

    try sim.run(60);
    for (0..60) |_| @import("systems.zig").movement(&reference, sim.dt);

    try testing.expectEqual(reference.stateHash(), sim.stateHash());
}

/// A one-shot system that queues a single deferred spawn on its first tick, so a
/// `spawned` event is emitted at flush for the dispatch tests below.
const OneShotSpawner = struct {
    var did: bool = false;
    fn system(ctx: *Context) SystemError!void {
        if (!did) {
            _ = try ctx.commands.spawn(ctx.gpa, ctx.world, .{});
            did = true;
        }
    }
};

test "sim: event dispatch is a no-op when no script is loaded" {
    // Runs in every build (default included): a Sim with no handler table must
    // dispatch its `spawned` event harmlessly.
    OneShotSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.addSystem(OneShotSpawner.system);

    try sim.tick();
    try testing.expectEqual(@as(usize, 1), sim.world.count()); // spawn applied
    try testing.expect(sim.script_runtime.handlerFieldInt("spawns") == null); // no table
}

test "sim: a spawned entity fires the Lua on_spawn handler (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { spawns = 0 }
        \\function t.on_spawn(self) t.spawns = t.spawns + 1 end
        \\return t
    );
    try sim.addSystem(OneShotSpawner.system);

    try sim.tick(); // spawner queues a spawn → flush emits `spawned` → on_spawn
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("spawns").?);

    try sim.tick(); // one-shot: no further spawn, so no further on_spawn
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("spawns").?);
}

test "sim: on_spawn reads its entity's position and sim time via the mana host seam (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    // Spawn one entity with a known transform on tick 3 (of a dt=1s sim), so the
    // handler observes position (7,0,0), a valid handle, and now == 3 — the latter
    // distinct from the no-host fallback (0), proving the engine really installed
    // the ADR 0015 host around dispatch.
    const Spawner = struct {
        var did: bool = false;
        fn system(ctx: *Context) SystemError!void {
            if (!did and ctx.tick == 3) {
                _ = try ctx.commands.spawn(ctx.gpa, ctx.world, .{ .transform = .{ .pos = .{ .x = 7, .y = 0, .z = 0 } } });
                did = true;
            }
        }
    };
    Spawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0); // dt = 1s → now is a whole number
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { px = -1, valid = -1, seen_now = -1 }
        \\function t.on_spawn(self)
        \\  local x, y, z = mana.position(self)
        \\  t.px = x
        \\  t.valid = mana.is_valid(self) and 1 or 0
        \\  t.seen_now = mana.now()
        \\end
        \\return t
    );
    try sim.addSystem(Spawner.system);

    try sim.run(4); // ticks 0..3; the tick-3 spawn flushes → on_spawn reads via mana
    try testing.expectEqual(@as(i64, 7), sim.script_runtime.handlerFieldInt("px").?);
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("valid").?);
    try testing.expectEqual(@as(i64, 3), sim.script_runtime.handlerFieldInt("seen_now").?);
}

test "sim: on_scene_enter fires host-live with ev.scene and bootstraps via mana (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    // A prototype the bootstrap handler spawns — proving the host is live during
    // on_scene_enter (spawn works) and that ev.scene carries the scene name.
    const protos = [_]prototype.Prototype{
        .{ .name = "thing", .health = .{ .current = 2, .max = 2 } },
    };

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = &protos };
    try sim.loadScript(
        \\local t = { name_ok = 0, valid = 0 }
        \\function t.on_scene_enter(ev)
        \\  t.name_ok = (ev.scene == "board") and 1 or 0
        \\  local h = mana.spawn("thing", 3, 4, 0)
        \\  t.valid = mana.is_valid(h) and 1 or 0
        \\end
        \\return t
    );
    sim.enterScene("board");

    try sim.tick(); // tick 0: on_scene_enter fires host-live → spawns "thing" (reserved)
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("name_ok").?); // ev.scene passed
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("valid").?); // reserved handle valid
    try sim.tick(); // tick 1: flush attaches the prototype's components

    try testing.expectEqual(@as(usize, 1), sim.world.count());
    const e = sim.world.entityAt(0);
    try testing.expect(sim.world.getTransform(e).?.pos.approxEql(.{ .x = 3, .y = 4, .z = 0 }, 1e-6));
    try testing.expectEqual(@as(f32, 2), sim.world.getHealth(e).?.current);
}

test "sim: on_scene_enter is a no-op when enterScene was never called (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { fired = 0 }
        \\function t.on_scene_enter(ev) t.fired = 1 end
        \\return t
    );
    // No enterScene: the handler must never run.
    try sim.run(3);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("fired").?);
}

test "sim: a key press then release dispatches on_key edges with name + flag (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { presses = 0, releases = 0, last_up = 0 }
        \\function t.on_key(ev)
        \\  if ev.pressed then
        \\    t.presses = t.presses + 1
        \\    t.last_up = (ev.key == "up") and 1 or 0
        \\  else
        \\    t.releases = t.releases + 1
        \\  end
        \\end
        \\return t
    );

    var held = platform.KeySet.initEmpty();
    held.insert(.up);
    sim.setInput(.{ .keys = held });
    try sim.tick(); // up newly held → on_key(key="up", pressed=true)
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("presses").?);
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("last_up").?);

    sim.setInput(.{}); // up released
    try sim.tick(); // up no longer held → on_key(pressed=false)
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("releases").?);

    try sim.tick(); // no change this tick → no further on_key
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("presses").?);
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("releases").?);
}

test "sim: mana.key_down polls this tick's held InputSnapshot, not just the on_key edge (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { up_down = 0, left_down = 0, bogus_down = 0 }
        \\function t.on_key(ev)
        \\  t.up_down = mana.key_down("up") and 1 or 0
        \\  t.left_down = mana.key_down("left") and 1 or 0
        \\  t.bogus_down = mana.key_down("not_a_real_key") and 1 or 0
        \\end
        \\return t
    );

    var held = platform.KeySet.initEmpty();
    held.insert(.up);
    sim.setInput(.{ .keys = held });
    try sim.tick(); // "up" newly held fires on_key; key_down("up") reads this tick's snapshot
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("up_down").?);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("left_down").?);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("bogus_down").?);
}

test "sim: mana.every fires a Lua timer host-live each interval (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    const protos = [_]prototype.Prototype{.{ .name = "dot" }};

    var sim = Sim.init(testing.allocator, 1.0); // dt = 1s, so timers fire on whole seconds
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = &protos };
    try sim.loadScript(
        \\local t = { ticks = 0 }
        \\function t.on_scene_enter(ev)
        \\  mana.every(1.0, function()
        \\    t.ticks = t.ticks + 1
        \\    mana.spawn("dot", t.ticks, 0, 0)  -- proves the host is live inside the timer
        \\  end)
        \\end
        \\return t
    );
    sim.enterScene("board");

    try sim.run(3); // on_scene_enter schedules every(1s); it fires at sim-time 1, 2, 3
    try testing.expectEqual(@as(i64, 3), sim.script_runtime.handlerFieldInt("ticks").?);
    try testing.expectEqual(@as(usize, 3), sim.world.count()); // one dot reserved per fire
}

test "sim: mana.after fires once then never again (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { fires = 0 }
        \\function t.on_scene_enter(ev) mana.after(1.0, function() t.fires = t.fires + 1 end) end
        \\return t
    );
    sim.enterScene("board");

    try sim.run(5); // due at sim-time 1; a one-shot must not re-fire on later ticks
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("fires").?);
}

test "sim: mana.cancel stops a scheduled timer from firing (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { fires = 0 }
        \\function t.on_scene_enter(ev)
        \\  local h = mana.every(1.0, function() t.fires = t.fires + 1 end)
        \\  mana.cancel(h)  -- cancel before it ever fires
        \\end
        \\return t
    );
    sim.enterScene("board");

    try sim.run(5);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("fires").?);
}

/// A one-shot system that spawns a single transform-only entity on its first tick,
/// so a `spawned` event drives the on_spawn mutation tests below.
const OneShotTransformSpawner = struct {
    var did: bool = false;
    fn system(ctx: *Context) SystemError!void {
        if (!did) {
            _ = try ctx.commands.spawn(ctx.gpa, ctx.world, .{ .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } });
            did = true;
        }
    }
};

test "sim: on_spawn queues mana.set_velocity; it attaches at the next flush (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotTransformSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = {}
        \\function t.on_spawn(self) mana.set_velocity(self, 1, 2, 3) end
        \\return t
    );
    try sim.addSystem(OneShotTransformSpawner.system);

    try sim.tick(); // spawn flush → on_spawn queues set_velocity (deferred, ADR 0003 §2)
    const e = sim.world.entityAt(0);
    try testing.expect(sim.world.getVelocity(e) == null); // not applied within the same tick
    try sim.tick(); // next flush applies the queued mutation
    try testing.expect(sim.world.getVelocity(e).?.v.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
}

test "sim: on_spawn queues mana.set_position; the entity teleports at the next flush (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotTransformSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = {}
        \\function t.on_spawn(self) mana.set_position(self, 9, 8, 7) end
        \\return t
    );
    try sim.addSystem(OneShotTransformSpawner.system); // spawns an entity at the origin

    try sim.tick(); // spawn flush → on_spawn queues set_position (deferred, ADR 0020)
    const e = sim.world.entityAt(0);
    try testing.expect(sim.world.getTransform(e).?.pos.approxEql(.{ .x = 0, .y = 0, .z = 0 }, 1e-6)); // not yet
    try sim.tick(); // next flush applies the teleport
    try testing.expect(sim.world.getTransform(e).?.pos.approxEql(.{ .x = 9, .y = 8, .z = 7 }, 1e-6));
}

test "sim: on_spawn queues mana.despawn(self); the entity is removed at the next flush (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotTransformSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = {}
        \\function t.on_spawn(self) mana.despawn(self) end
        \\return t
    );
    try sim.addSystem(OneShotTransformSpawner.system);

    try sim.tick(); // spawn flush → on_spawn queues despawn (deferred)
    try testing.expectEqual(@as(usize, 1), sim.world.count()); // still alive this tick
    try sim.tick(); // next flush applies the despawn
    try testing.expectEqual(@as(usize, 0), sim.world.count());
}

test "sim: on_spawn spawns a prototype via mana; its components attach at the next flush (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotTransformSpawner.did = false;

    // A "food" prototype with velocity + health but no template transform (so the
    // spawn point supplies its position). Outlives `sim` — the registry borrows it.
    const protos = [_]prototype.Prototype{
        .{ .name = "food", .velocity = .{ .v = .{ .x = 1, .y = 0, .z = 0 } }, .health = .{ .current = 3, .max = 3 } },
    };

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    sim.prototypes = .{ .prototypes = &protos };
    try sim.loadScript(
        \\local t = { done = false, handle = 0, valid = 0 }
        \\function t.on_spawn(self)
        \\  if not t.done then           -- spawn exactly once, so the food's own
        \\    t.done = true              -- on_spawn does not spawn again (no loop)
        \\    t.handle = mana.spawn("food", 5, 6, 7)
        \\    t.valid = mana.is_valid(t.handle) and 1 or 0
        \\  end
        \\end
        \\return t
    );
    try sim.addSystem(OneShotTransformSpawner.system);

    try sim.tick(); // system spawns entity A → on_spawn(A) → mana.spawn("food") reserves B
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("valid").?); // B valid at once
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("handle").?); // B = index 1, gen 0 → 1
    try sim.tick(); // next flush attaches B's prototype components

    try testing.expectEqual(@as(usize, 2), sim.world.count()); // A + B
    const b = sim.world.entityAt(1);
    try testing.expect(sim.world.getTransform(b).?.pos.approxEql(.{ .x = 5, .y = 6, .z = 7 }, 1e-6)); // spawn point
    try testing.expect(sim.world.getVelocity(b).?.v.approxEql(.{ .x = 1, .y = 0, .z = 0 }, 1e-6)); // from prototype
    try testing.expectEqual(@as(f32, 3), sim.world.getHealth(b).?.current); // from prototype
}

/// A one-shot system that spawns an entity carrying a "hp" data component on its
/// first tick, so on_spawn can read/write it via `mana.get`/`mana.set`.
const OneShotDataSpawner = struct {
    var did: bool = false;
    fn system(ctx: *Context) SystemError!void {
        if (!did) {
            _ = try ctx.commands.spawn(ctx.gpa, ctx.world, .{
                .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
                .data = &.{.{ .name = "hp", .value = 3 }},
            });
            did = true;
        }
    }
};

test "sim: on_spawn reads a data component and queues mana.set; it applies at the next flush (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotDataSpawner.did = false;

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { seen = -1 }
        \\function t.on_spawn(self)
        \\  t.seen = mana.get(self, "hp")          -- the spawn attached hp = 3
        \\  mana.set(self, "hp", mana.get(self, "hp") + 10) -- deferred: hp := 13
        \\end
        \\return t
    );
    try sim.addSystem(OneShotDataSpawner.system);

    try sim.tick(); // spawn flush attaches hp=3 → on_spawn reads 3, queues hp=13
    const e = sim.world.entityAt(0);
    const col = sim.world.dataColumn("hp").?;
    try testing.expectEqual(@as(i64, 3), sim.script_runtime.handlerFieldInt("seen").?);
    try testing.expectEqual(@as(?f64, 3), sim.world.getData(e, col)); // set not applied within the same tick
    try sim.tick(); // next flush applies the queued mana.set
    try testing.expectEqual(@as(?f64, 13), sim.world.getData(e, col));
}

test "sim: mana.get on an undeclared data component is nil and mana.set on it is dropped (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;
    OneShotTransformSpawner.did = false; // spawns a bare transform entity, no data columns

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { was_nil = -1 }
        \\function t.on_spawn(self)
        \\  t.was_nil = (mana.get(self, "nope") == nil) and 1 or 0
        \\  mana.set(self, "nope", 5) -- undeclared: dropped with a warning, never a crash
        \\end
        \\return t
    );
    try sim.addSystem(OneShotTransformSpawner.system);

    try sim.tick();
    try sim.tick(); // a dropped set never registers a column, so nothing to apply
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("was_nil").?);
    try testing.expect(sim.world.dataColumn("nope") == null); // still undeclared
}

test "sim: mana.random/random_int draw from the sim's seeded core.Rng, in range (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    sim.setRngSeed(12345);
    try sim.loadScript(
        \\local t = { in_range = 1, in_unit = 1, sample = -1 }
        \\function t.on_scene_enter(ev)
        \\  for i = 1, 20 do
        \\    local f = mana.random()
        \\    if f < 0 or f >= 1 then t.in_unit = 0 end
        \\    local n = mana.random_int(10, 20)
        \\    if n < 10 or n > 20 then t.in_range = 0 end
        \\  end
        \\  -- scale to an integer so the test can read it back (handlerFieldInt is
        \\  -- int-only); locks the first draw's magnitude loosely, not exactly.
        \\  t.sample = math.floor(mana.random() * 1000000)
        \\end
        \\return t
    );
    sim.enterScene("board");

    try sim.tick();
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("in_unit").?);
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("in_range").?);
    const sample = sim.script_runtime.handlerFieldInt("sample").?;
    try testing.expect(sample >= 0 and sample < 1000000);
}

/// Runs `on_scene_enter` once and returns `mana.random_int(1, 1000000)`'s draw via
/// `handlerFieldInt`, for the determinism test below.
fn firstRandomIntDraw(seed: u64) !i64 {
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    sim.setRngSeed(seed);
    try sim.loadScript(
        \\local t = { draw = -1 }
        \\function t.on_scene_enter(ev) t.draw = mana.random_int(1, 1000000) end
        \\return t
    );
    sim.enterScene("board");
    try sim.tick();
    return sim.script_runtime.handlerFieldInt("draw").?;
}

test "sim: mana.random_int is deterministic — same seed, same draw; a different seed diverges (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    const a = try firstRandomIntDraw(777);
    const b = try firstRandomIntDraw(777);
    try testing.expectEqual(a, b);

    const c = try firstRandomIntDraw(778);
    try testing.expect(a != c);
}

test "sim: an unseeded Sim's mana.random_int still runs deterministically off default_rng_seed (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    // No `setRngSeed` call on either sim: both fall back to `default_rng_seed`.
    var sim_a = Sim.init(testing.allocator, 1.0);
    defer sim_a.deinit();
    try sim_a.loadScript(
        \\local t = { draw = -1 }
        \\function t.on_scene_enter(ev) t.draw = mana.random_int(1, 1000000) end
        \\return t
    );
    sim_a.enterScene("board");
    try sim_a.tick();

    var sim_b = Sim.init(testing.allocator, 1.0);
    defer sim_b.deinit();
    try sim_b.loadScript(
        \\local t = { draw = -1 }
        \\function t.on_scene_enter(ev) t.draw = mana.random_int(1, 1000000) end
        \\return t
    );
    sim_b.enterScene("board");
    try sim_b.tick();

    try testing.expectEqual(
        sim_a.script_runtime.handlerFieldInt("draw").?,
        sim_b.script_runtime.handlerFieldInt("draw").?,
    );
}

/// Two focusable buttons in a row, the same fixture shape `ui_dispatch.zig`'s own
/// tests use: button "a" spans x∈[0,50), button "b" x∈[50,100) of a 100×20 viewport.
const ui_input_two_buttons: ui.Screen = .{ .root = .{
    .kind = .container,
    .layout = .flex,
    .direction = .row,
    .children = &[_]ui.Widget{
        .{ .kind = .label, .id = "a", .focusable = true, .width = 50 },
        .{ .kind = .label, .id = "b", .focusable = true, .width = 50 },
    },
} };

test "sim: with no active UI screen, tick's ui_input never claims a key (any build)" {
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try testing.expect(sim.ui_input.screen == null); // default: nothing to consume

    var held = platform.KeySet.initEmpty();
    held.insert(.right);
    sim.setInput(.{ .keys = held });
    try sim.tick(); // no UI screen active ⇒ ui_input claims nothing
    try testing.expect(sim.ui_input.focus.current == null); // UI focus never moved
}

test "sim: Sim.tick routes a right-arrow press into ui_input.setScreen's focus nav (issue #209, any build)" {
    // Proves the wiring end-to-end through `Sim.tick` — not `ui_dispatch.UiInput`
    // directly — the same seam `runtime/main.zig`'s `--play` loop drives via
    // `sim.setInput(window.poll())`. Runs under BOTH builds: with no Lua loaded,
    // dispatch is a no-op but the focus math (this test's assertion) still runs.
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    sim.ui_input.setScreen(&ui_input_two_buttons, .{ .x = 0, .y = 0, .w = 100, .h = 20 });

    var held = platform.KeySet.initEmpty();
    held.insert(.right);
    sim.setInput(.{ .keys = held });
    try sim.tick(); // right-arrow press, nothing focused yet ⇒ UI bootstraps focus onto "a"
    try testing.expectEqual(&ui_input_two_buttons.root.children[0], sim.ui_input.focus.current.?);

    sim.setInput(.{}); // release
    try sim.tick();
    sim.setInput(.{ .keys = held }); // right-arrow press again ⇒ moves onto "b"
    try sim.tick();
    try testing.expectEqual(&ui_input_two_buttons.root.children[1], sim.ui_input.focus.current.?);
}

test "sim: a UI-claimed key press does not also dispatch on_key, but an unclaimed key still does (requires -Denable-lua)" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    try sim.loadScript(
        \\local t = { key_presses = 0, focuses = 0, activates = 0 }
        \\function t.on_key(ev) if ev.pressed then t.key_presses = t.key_presses + 1 end end
        \\function t.on_focus(ev) t.focuses = t.focuses + 1 end
        \\function t.on_activate(ev) t.activates = t.activates + 1 end
        \\return t
    );
    sim.ui_input.setScreen(&ui_input_two_buttons, .{ .x = 0, .y = 0, .w = 100, .h = 20 });

    // A right-arrow press is a recognized nav key: the UI claims it (bootstraps
    // focus onto "a", fires on_focus) and on_key must NOT also fire for it.
    var right = platform.KeySet.initEmpty();
    right.insert(.right);
    sim.setInput(.{ .keys = right });
    try sim.tick();
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("focuses").?);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("key_presses").?);

    sim.setInput(.{}); // release right
    try sim.tick();

    // Enter activates the focused widget "a": the UI claims it, on_activate fires,
    // on_key still never fires for "enter".
    var enter = platform.KeySet.initEmpty();
    enter.insert(.enter);
    sim.setInput(.{ .keys = enter });
    try sim.tick();
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("activates").?);
    try testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("key_presses").?);

    sim.setInput(.{}); // release enter
    try sim.tick();

    // "w" has no UI meaning (not a nav/activate key): the screen claims nothing,
    // so it falls through to gameplay's on_key exactly as ADR 0021 already does.
    var w = platform.KeySet.initEmpty();
    w.insert(.w);
    sim.setInput(.{ .keys = w });
    try sim.tick();
    try testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("key_presses").?);
}
