//! Deterministic timer facility (ADR 0007's "timer wheel" follow-on; the engine-side
//! backing for ADR 0003 §2 `mana.after`/`every`, before scripting is wired). `Timers`
//! tracks scheduled one-shot and repeating callbacks purely in accumulated sim time
//! (seconds) — never wall clock, so the same tick/dt sequence always fires the same
//! callbacks in the same order (CLAUDE.md determinism invariant). `advance` fires
//! every entry whose fire-time is due, in deterministic (fire-time, insertion-order)
//! order, then re-arms repeating entries.
//!
//! The `Callback` is a tagged union: a plain engine `native` function, or a `closure`
//! (opaque context + fn) so scripting (#55) can bind a Lua handler reference behind
//! the same wheel. The wheel fires either uniformly and stays caller-agnostic.

const std = @import("std");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// A scheduled timer callback. `native` is a plain engine function receiving the
/// world to mutate directly; `closure` carries an opaque `context` so a caller can
/// bind per-timer state behind the same wheel — e.g. scripting (#55) stores a Lua
/// handler reference in the context. `advance` fires either variant uniformly, so the
/// wheel is closure-capable without knowing about any specific caller.
pub const Callback = union(enum) {
    native: *const fn (*World) void,
    closure: struct {
        context: *anyopaque,
        func: *const fn (context: *anyopaque, world: *World) void,
    },

    /// Invoke the callback against `world`.
    pub fn fire(self: Callback, world: *World) void {
        switch (self) {
            .native => |f| f(world),
            .closure => |c| c.func(c.context, world),
        }
    }
};

/// Opaque, generational reference to a scheduled timer, returned by `after`/`every`.
/// `cancel` on a stale handle (already fired one-shot, already cancelled, or a
/// reused slot's old generation) is a no-op — mirrors `Entity`'s generation-check
/// semantics (`ecs/entity.zig`).
pub const Handle = struct {
    index: u32,
    generation: u32,
};

const Entry = struct {
    /// Accumulated sim time (seconds) at which this entry next fires.
    fire_at: f32,
    /// Non-null for a repeating timer: seconds re-added to `fire_at` after each
    /// fire. Null for a one-shot, which deactivates itself after firing once.
    interval: ?f32,
    callback: Callback,
    generation: u32,
    /// False for a free slot (never scheduled, or fired-and-done/cancelled) —
    /// reused by the next `after`/`every` before the list grows.
    active: bool,
    /// Monotonic insertion order; the deterministic tie-break for entries that fire
    /// on the same `advance` call.
    seq: u64,
};

/// Scheduled one-shot and repeating callbacks, advanced by accumulated dt. No wall
/// clock anywhere: two `Timers` fed the same `after`/`every`/`advance` sequence fire
/// bit-for-bit identically.
pub const Timers = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Accumulated sim time in seconds since this `Timers` was created.
    now: f32 = 0,
    /// Next insertion sequence number (never reused, even across slot reuse) — the
    /// deterministic tie-break for same-fire-time entries.
    next_seq: u64 = 0,

    pub fn deinit(self: *Timers, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// Schedule `cb` to fire once, `delay_seconds` from now (in accumulated sim
    /// time). Returns a handle that can `cancel` it before it fires.
    pub fn after(self: *Timers, gpa: Allocator, delay_seconds: f32, cb: Callback) Allocator.Error!Handle {
        return self.schedule(gpa, delay_seconds, null, cb);
    }

    /// Schedule `cb` to fire every `interval_seconds`, starting one interval from
    /// now. Returns a handle that can `cancel` it (stopping future fires).
    pub fn every(self: *Timers, gpa: Allocator, interval_seconds: f32, cb: Callback) Allocator.Error!Handle {
        return self.schedule(gpa, interval_seconds, interval_seconds, cb);
    }

    fn schedule(self: *Timers, gpa: Allocator, delay_seconds: f32, interval: ?f32, cb: Callback) Allocator.Error!Handle {
        const fire_at = self.now + delay_seconds;
        const seq = self.next_seq;
        self.next_seq += 1;
        // Reuse the first free slot so cancelled/fired one-shots don't leak growth.
        for (self.entries.items, 0..) |*e, i| {
            if (!e.active) {
                const generation = e.generation +% 1;
                e.* = .{ .fire_at = fire_at, .interval = interval, .callback = cb, .generation = generation, .active = true, .seq = seq };
                return .{ .index = @intCast(i), .generation = generation };
            }
        }
        const index: u32 = @intCast(self.entries.items.len);
        try self.entries.append(gpa, .{ .fire_at = fire_at, .interval = interval, .callback = cb, .generation = 0, .active = true, .seq = seq });
        return .{ .index = index, .generation = 0 };
    }

    /// Prevent a scheduled timer from firing again.
    pub fn cancel(self: *Timers, handle: Handle) void {
        if (handle.index >= self.entries.items.len) return;
        const e = &self.entries.items[handle.index];
        if (e.active and e.generation == handle.generation) e.active = false;
    }

    /// Advance accumulated time by `dt` seconds and fire every due entry, in
    /// deterministic (fire-time, insertion-order) order. One-shots deactivate after
    /// firing; repeating entries re-arm by adding their interval (at most one fire
    /// per entry per `advance` call — a repeating timer whose interval is smaller
    /// than `dt` catches up gradually across subsequent calls rather than bursting,
    /// which stays deterministic and is simplest for v1).
    pub fn advance(self: *Timers, gpa: Allocator, world: *World, dt: f32) Allocator.Error!void {
        self.now += dt;

        var due: std.ArrayList(u32) = .empty;
        defer due.deinit(gpa);
        for (self.entries.items, 0..) |e, i| {
            if (e.active and e.fire_at <= self.now) try due.append(gpa, @intCast(i));
        }
        std.sort.pdq(u32, due.items, self.entries.items, dueLessThan);

        for (due.items) |i| {
            const e = &self.entries.items[i];
            e.callback.fire(world);
            if (e.interval) |interval| {
                e.fire_at += interval;
            } else {
                e.active = false;
            }
        }
    }
};

/// Deterministic ordering for entries firing on the same `advance` call: earliest
/// scheduled fire-time first, insertion order breaks ties.
fn dueLessThan(entries: []const Entry, a: u32, b: u32) bool {
    const ea = entries[a];
    const eb = entries[b];
    if (ea.fire_at != eb.fire_at) return ea.fire_at < eb.fire_at;
    return ea.seq < eb.seq;
}

const testing = std.testing;

test "timers: one-shot fires at the scheduled time, not before, and only once" {
    const Counter = struct {
        var count: u32 = 0;
        fn cb(_: *World) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    _ = try timers.after(testing.allocator, 0.25, .{ .native = Counter.cb });
    try timers.advance(testing.allocator, &world, 0.1); // now = 0.1, not due
    try testing.expectEqual(@as(u32, 0), Counter.count);
    try timers.advance(testing.allocator, &world, 0.1); // now = 0.2, still not due
    try testing.expectEqual(@as(u32, 0), Counter.count);
    try timers.advance(testing.allocator, &world, 0.1); // now = 0.3, due -> fires
    try testing.expectEqual(@as(u32, 1), Counter.count);
    try timers.advance(testing.allocator, &world, 1.0); // one-shot: does not re-fire
    try testing.expectEqual(@as(u32, 1), Counter.count);
}

test "timers: repeating timer re-fires every interval" {
    const Counter = struct {
        var count: u32 = 0;
        fn cb(_: *World) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    _ = try timers.every(testing.allocator, 0.1, .{ .native = Counter.cb });
    for (0..5) |i| {
        try timers.advance(testing.allocator, &world, 0.1);
        try testing.expectEqual(@as(u32, @intCast(i + 1)), Counter.count);
    }
}

test "timers: cancel prevents a scheduled callback from firing" {
    const Counter = struct {
        var count: u32 = 0;
        fn cb(_: *World) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    const h = try timers.after(testing.allocator, 0.1, .{ .native = Counter.cb });
    timers.cancel(h);
    try timers.advance(testing.allocator, &world, 1.0);
    try testing.expectEqual(@as(u32, 0), Counter.count);
}

test "timers: cancel on an already-fired handle is a no-op (stale generation)" {
    const Counter = struct {
        var count: u32 = 0;
        fn cb(_: *World) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    const h = try timers.after(testing.allocator, 0.1, .{ .native = Counter.cb });
    try timers.advance(testing.allocator, &world, 0.1); // fires, slot freed
    try testing.expectEqual(@as(u32, 1), Counter.count);

    // A new timer reuses the freed slot with a bumped generation.
    _ = try timers.after(testing.allocator, 10.0, .{ .native = Counter.cb });
    timers.cancel(h); // stale generation -> must not touch the new entry
    try timers.advance(testing.allocator, &world, 100.0);
    try testing.expectEqual(@as(u32, 2), Counter.count); // the new entry still fired
}

test "timers: same-tick fires are ordered by fire-time then insertion order" {
    const Order = struct {
        var log: std.ArrayList(u8) = .empty;
        fn a(_: *World) void {
            log.append(testing.allocator, 'a') catch unreachable;
        }
        fn b(_: *World) void {
            log.append(testing.allocator, 'b') catch unreachable;
        }
        fn c(_: *World) void {
            log.append(testing.allocator, 'c') catch unreachable;
        }
    };
    Order.log = .empty;
    defer Order.log.deinit(testing.allocator);

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    _ = try timers.after(testing.allocator, 0.1, .{ .native = Order.a }); // seq 0, fires at 0.1
    _ = try timers.after(testing.allocator, 0.1, .{ .native = Order.b }); // seq 1, fires at 0.1 (tie with a)
    _ = try timers.after(testing.allocator, 0.05, .{ .native = Order.c }); // seq 2, fires at 0.05 (earliest)

    try timers.advance(testing.allocator, &world, 0.2); // all three are due at once
    try testing.expectEqualSlices(u8, "cab", Order.log.items);
}

test "timers: a closure callback fires through its bound context" {
    // Proves the wheel is closure-capable (#55): the callback reaches per-timer state
    // via its opaque context, not a bare function — the shape a Lua timer uses.
    const Ctx = struct {
        count: u32 = 0,
        fn tick(context: *anyopaque, _: *World) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var ctx: Ctx = .{};

    var world = World.init(testing.allocator);
    defer world.deinit();
    var timers: Timers = .{};
    defer timers.deinit(testing.allocator);

    _ = try timers.every(testing.allocator, 0.1, .{ .closure = .{ .context = &ctx, .func = Ctx.tick } });
    try timers.advance(testing.allocator, &world, 0.1);
    try timers.advance(testing.allocator, &world, 0.1);
    try testing.expectEqual(@as(u32, 2), ctx.count); // fired twice, through its context
}
