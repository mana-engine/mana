//! The fixed-timestep frame (ADR 0007 §1). `Sim` owns the world, an ordered list of
//! systems, a command buffer, an event queue, and event handlers. `tick` runs the
//! deterministic frame: systems → flush commands → dispatch events. Registering a
//! system or handler is the seam scripting and physics plug into, so subsystems
//! compose here instead of editing runtime orchestration. Rendering is separate
//! (render-side, ADR 0006).

const std = @import("std");
const World = @import("world.zig").World;
const command = @import("command.zig");
const event = @import("event.zig");

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

    /// Advance one fixed step: run systems, flush deferred commands (emitting
    /// lifecycle events), dispatch all events, then clear.
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
