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

const Allocator = std.mem.Allocator;

/// What a system receives each tick. Systems read/iterate `world` and record
/// deferred changes into `commands` (using `gpa`); they may enqueue `events`.
pub const Context = struct {
    world: *World,
    commands: *command.CommandBuffer,
    events: *event.Queue,
    gpa: Allocator,
    dt: f32,
    tick: u64,
};

/// A system: a free function over a `Context`. May fail only on allocation.
pub const System = *const fn (*Context) Allocator.Error!void;

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
    dt: f32,
    tick_count: u64 = 0,

    /// A sim with an empty world at fixed step `dt`. Populate `world` (e.g. via
    /// `engine.scene.load`) and register systems, then `run`/`tick`.
    pub fn init(gpa: Allocator, dt: f32) Sim {
        return .{ .gpa = gpa, .world = World.init(gpa), .dt = dt };
    }

    pub fn deinit(self: *Sim) void {
        self.systems.deinit(self.gpa);
        self.handlers.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.commands.deinit(self.gpa);
        self.timers.deinit(self.gpa);
        self.world.deinit();
        self.* = undefined;
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

    /// Advance one fixed step: run systems, flush deferred commands (emitting
    /// lifecycle events), dispatch all events, advance timers (firing any now due),
    /// then increment the tick counter.
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
        };
        for (self.systems.items) |system| try system(&ctx);
        try self.commands.flush(self.gpa, &self.world, &self.events);
        for (self.events.items()) |ev| {
            for (self.handlers.items) |handler| handler(&self.world, ev);
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
        fn system(ctx: *Context) Allocator.Error!void {
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
