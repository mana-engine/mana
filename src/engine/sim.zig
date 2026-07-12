//! The fixed-timestep frame (ADR 0007 §1). `Sim` owns the world, an ordered list of
//! systems, a command buffer, an event queue, event handlers, and a `Timers` (the
//! engine-side backing for ADR 0003 §2 `mana.after`/`every`). `tick` runs the
//! deterministic frame: systems → flush commands → dispatch events → advance
//! timers. Registering a system or handler is the seam scripting and physics plug
//! into, so subsystems compose here instead of editing runtime orchestration.
//! Rendering is separate (render-side, ADR 0006).

const std = @import("std");
const World = @import("world.zig").World;
const command = @import("command.zig");
const event = @import("event.zig");
const timer = @import("timer.zig");
const script_runtime = @import("script_runtime.zig");
const script = @import("script");
const platform = @import("platform");
const prototype = @import("prototype.zig");

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
    /// The `InputSnapshot` the next `tick` exposes to systems via `Context.input`
    /// (ADR 0009 §3/§4), set by `setInput`. Defaults to an all-empty snapshot, so a
    /// `Sim` that never calls `setInput` — every existing caller today — ticks
    /// exactly as it did before input delivery existed.
    input: platform.InputSnapshot = .{},
    dt: f32,
    tick_count: u64 = 0,

    /// A sim with an empty world at fixed step `dt`. Populate `world` (e.g. via
    /// `engine.scene.load`) and register systems, then `run`/`tick`.
    pub fn init(gpa: Allocator, dt: f32) Sim {
        return .{ .gpa = gpa, .world = World.init(gpa), .dt = dt };
    }

    pub fn deinit(self: *Sim) void {
        self.script_runtime.deinit(self.gpa);
        self.systems.deinit(self.gpa);
        self.handlers.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.commands.deinit(self.gpa);
        self.timers.deinit(self.gpa);
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
    pub fn after(self: *Sim, delay_seconds: f32, cb: timer.Callback) Allocator.Error!timer.Handle {
        return self.timers.after(self.gpa, delay_seconds, cb);
    }

    /// Schedule `cb` to fire every `interval_seconds` of sim time (ADR 0003 §2
    /// `mana.every`). Fired at the end of `tick`, after event dispatch.
    pub fn every(self: *Sim, interval_seconds: f32, cb: timer.Callback) Allocator.Error!timer.Handle {
        return self.timers.every(self.gpa, interval_seconds, cb);
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
        var ctx: Context = .{
            .world = &self.world,
            .commands = &self.commands,
            .events = &self.events,
            .gpa = self.gpa,
            .dt = self.dt,
            .tick = self.tick_count,
            .input = self.input,
        };
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
        try self.commands.flush(self.gpa, &self.world, &self.events);
        // Sim time exposed to script `mana.now` this dispatch (ADR 0003 §2 / ADR
        // 0015): tick-derived seconds elapsed at the start of this tick, so it is
        // deterministic and never reads a wall clock.
        const now_seconds: f64 = @as(f64, @floatFromInt(self.tick_count)) * @as(f64, self.dt);
        // TODO(tracy): bound all script dispatch this frame in one Tracy zone with
        // the ADR 0003 §6 per-frame budget once the Tracy port lands.
        for (self.events.items()) |ev| {
            for (self.handlers.items) |handler| handler(&self.world, ev);
            // Script dispatch (ADR 0003 §1/§3). A comptime no-op — zero cost, sim
            // bit-identical — unless `-Denable-lua`; catches handler errors (§9) and
            // rolls back their queued mutations. The live world, command buffer,
            // `now`, and prototype registry back the ADR 0015 host seam for the
            // handler's `mana` reads and deferred mutations (applied at next tick's
            // flush). Only OOM propagates.
            try self.script_runtime.dispatch(ev, .{
                .world = &self.world,
                .commands = &self.commands,
                .gpa = self.gpa,
                .now_seconds = now_seconds,
                .prototypes = self.prototypes,
            });
        }
        self.events.clear();
        try self.timers.advance(self.gpa, &self.world, self.dt);
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
