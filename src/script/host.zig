//! The script↔engine host seam (ADR 0015): the abstract interface the live-Sim
//! `mana` accessors call through. `script` imports `core` only, so it cannot name
//! `World`/`CommandBuffer`/`ecs.Entity`; instead it declares this `core`-typed
//! vtable that `engine` fills for the duration of one event dispatch. Only
//! `core`/builtin types cross the seam — no Lua or engine type — so the module DAG
//! (`script → core`) and invariant #4 (Vulkan/engine internals never leak) hold.
//!
//! Compiled only under `-Denable-lua` (imported by `lua.zig`/`mana.zig`); no `zlua`
//! dependency itself, so this file is plain, dependency-free Zig over `core`.
//!
//! Wired: the read surface — `is_valid`, `position`, `now`, `get` (named data
//! components, ADR 0024), `random`, `random_int` (ADR 0022, issue #47), `is_walkable`
//! (the scene tilemap's walkability grid, ADR 0035) — and the deferred-mutation
//! surface — `set` (named data components, ADR 0024), `set_velocity`, `set_position`,
//! `despawn`, `spawn`, `timer_after`/`timer_every`/`timer_cancel` (queued on the
//! engine's command buffer/timer wheel, applied at the next flush). The *mechanism*
//! here is fixed by ADR 0015 and does not churn; the surface it carries grows only via
//! a new ADR per ADR 0003 §5.
//!
//! Mutations return nothing: they are fire-and-forget deferred commands (ADR 0003
//! §2). A stale handle is dropped at flush; allocation failure is recorded on the
//! engine-side ctx (not signalled through the seam) and aborts the tick — OOM is
//! never a content bug.

const core = @import("core");

/// A live view of the Sim a `mana` accessor may call into for the duration of one
/// event dispatch. `ctx` is an opaque pointer the engine owns and every vtable
/// function knows how to reinterpret; it is valid only while the engine has it
/// installed on a `State` (set around each dispatch, cleared after), so a `mana`
/// accessor invoked with no host present must degrade gracefully (nil/false) rather
/// than deref a stale `ctx`.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Function-pointer table over `core`-only types. `handle` is the ADR 0003 §4
    /// packed `u64` an opaque entity handle round-trips through Lua as. Grows
    /// additively as further #5 accessors land; the seam mechanism (ADR 0015) is
    /// fixed.
    pub const VTable = struct {
        /// True iff `handle` names a live entity (its generation matches the live
        /// slot). Stale/forged handles read `false` (ADR 0003 §2, §4).
        is_valid: *const fn (ctx: *anyopaque, handle: u64) bool,
        /// The entity's world position, or `null` if `handle` is stale or the
        /// entity has no `Transform` (ADR 0003 §2 `mana.position`).
        position: *const fn (ctx: *anyopaque, handle: u64) ?core.Vec3,
        /// Current sim time in seconds — tick-derived, never wall-clock, so it is
        /// deterministic and safe to branch on (ADR 0003 §2 `mana.now`).
        now: *const fn (ctx: *anyopaque) f64,
        /// Read entity `handle`'s named scalar data component `name` (ADR 0024
        /// `mana.get`) — an immediate read. `null` when the handle is stale, the
        /// entity lacks a value there, or `name` is not a declared data component
        /// (an undeclared name is `null`, never an error). `name` is borrowed for the
        /// call only.
        get: *const fn (ctx: *anyopaque, handle: u64, name: []const u8) ?f64,
        /// Queue a write of entity `handle`'s named scalar data component `name` to
        /// `value` (ADR 0024 `mana.set`), applied at the next flush (deferred, like
        /// `set_velocity`). An undeclared `name` is dropped with an engine warning; a
        /// stale handle is dropped at flush. `name` is borrowed for the call only —
        /// the host resolves it to a column id immediately, never storing the string.
        set: *const fn (ctx: *anyopaque, handle: u64, name: []const u8, value: f64) void,
        /// Queue a velocity change on `handle` (world units/sec), applied at the
        /// next flush (deferred mutation, ADR 0003 §2). A stale handle is dropped at
        /// flush; allocation failure is recorded engine-side and aborts the tick.
        set_velocity: *const fn (ctx: *anyopaque, handle: u64, v: core.Vec3) void,
        /// Queue a position change on `handle` (a discrete teleport, ADR 0020),
        /// applied at the next flush. Same deferred model as `set_velocity`.
        set_position: *const fn (ctx: *anyopaque, handle: u64, pos: core.Vec3) void,
        /// Queue a despawn of `handle`, applied at the next flush (deferred). A stale
        /// handle is dropped at flush.
        despawn: *const fn (ctx: *anyopaque, handle: u64) void,
        /// Spawn the prototype named `name` at `pos` (ADR 0016). Reserves an entity
        /// immediately and returns its packed handle (valid at once, components
        /// attach at the next flush, ADR 0003 §2). An unknown prototype returns a
        /// packed invalid handle (a content bug the engine logs), never a crash.
        spawn: *const fn (ctx: *anyopaque, name: []const u8, pos: core.Vec3) u64,
        /// Schedule Lua registry reference `ref` to fire once after `delay` seconds
        /// (ADR 0003 §2 `mana.after`; ADR 0019). Returns a packed timer handle. The
        /// engine owns `ref` until the timer fires or is cancelled.
        timer_after: *const fn (ctx: *anyopaque, ref: i32, delay: f32) u64,
        /// Schedule Lua registry reference `ref` to fire every `interval` seconds
        /// (`mana.every`). Returns a packed timer handle.
        timer_every: *const fn (ctx: *anyopaque, ref: i32, interval: f32) u64,
        /// Cancel the timer named by packed `handle` and release its Lua reference
        /// (`mana.cancel`). A stale handle is a no-op.
        timer_cancel: *const fn (ctx: *anyopaque, handle: u64) void,
        /// Uniform float in `[0, 1)` drawn from the sim's seeded `core.Rng`
        /// (`mana.random`, ADR 0022). Immediate, like `position`/`now` — never
        /// deferred, since it reads no world state and mutates only the RNG stream.
        random: *const fn (ctx: *anyopaque) f32,
        /// Uniform integer in the inclusive `[min(lo, hi), max(lo, hi)]` drawn from
        /// the same stream (`mana.random_int`, ADR 0022). Immediate, same as
        /// `random`. See `core.Rng.intRange` for the exact (version-stable) mapping.
        random_int: *const fn (ctx: *anyopaque, lo: i64, hi: i64) i64,
        /// True iff grid cell (`col`, `row`) is walkable on the sim's scene tilemap
        /// (`mana.is_walkable`, ADR 0035) — the same grid the native `nav` pathfinder
        /// (ADR 0027) paths over, read-only. `false` for an out-of-grid cell, a wall
        /// cell, or when the sim has no tilemap (no live Sim dispatching). Immediate,
        /// like `position`/`now` — this is a read of static level data, never queued.
        is_walkable: *const fn (ctx: *anyopaque, col: i32, row: i32) bool,
    };

    /// Thin forwarders so callers read `host.position(h)` rather than threading
    /// `ctx` by hand. Each just dispatches through the vtable.
    pub fn isValid(self: Host, handle: u64) bool {
        return self.vtable.is_valid(self.ctx, handle);
    }
    pub fn position(self: Host, handle: u64) ?core.Vec3 {
        return self.vtable.position(self.ctx, handle);
    }
    pub fn now(self: Host) f64 {
        return self.vtable.now(self.ctx);
    }
    pub fn get(self: Host, handle: u64, name: []const u8) ?f64 {
        return self.vtable.get(self.ctx, handle, name);
    }
    pub fn set(self: Host, handle: u64, name: []const u8, value: f64) void {
        self.vtable.set(self.ctx, handle, name, value);
    }
    pub fn setVelocity(self: Host, handle: u64, v: core.Vec3) void {
        self.vtable.set_velocity(self.ctx, handle, v);
    }
    pub fn setPosition(self: Host, handle: u64, pos: core.Vec3) void {
        self.vtable.set_position(self.ctx, handle, pos);
    }
    pub fn despawn(self: Host, handle: u64) void {
        self.vtable.despawn(self.ctx, handle);
    }
    pub fn spawn(self: Host, name: []const u8, pos: core.Vec3) u64 {
        return self.vtable.spawn(self.ctx, name, pos);
    }
    pub fn timerAfter(self: Host, ref: i32, delay: f32) u64 {
        return self.vtable.timer_after(self.ctx, ref, delay);
    }
    pub fn timerEvery(self: Host, ref: i32, interval: f32) u64 {
        return self.vtable.timer_every(self.ctx, ref, interval);
    }
    pub fn timerCancel(self: Host, handle: u64) void {
        self.vtable.timer_cancel(self.ctx, handle);
    }
    pub fn random(self: Host) f32 {
        return self.vtable.random(self.ctx);
    }
    pub fn randomInt(self: Host, lo: i64, hi: i64) i64 {
        return self.vtable.random_int(self.ctx, lo, hi);
    }
    pub fn isWalkable(self: Host, col: i32, row: i32) bool {
        return self.vtable.is_walkable(self.ctx, col, row);
    }
};

const testing = @import("std").testing;

test "host: forwarders dispatch through the vtable to a fake ctx" {
    // A minimal fake host (no engine, no Lua) proves the seam is callable with only
    // `core` types — the same shape a test double or the real engine impl fills.
    const Fake = struct {
        valid: bool,
        pos: core.Vec3,
        t: f64,
        last_despawned: u64 = 0,
        last_vel: core.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
        last_pos: core.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
        last_spawn_name: []const u8 = "",
        last_spawn_pos: core.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
        last_ref: i32 = 0,
        last_delay: f32 = 0,
        last_cancel: u64 = 0,
        random_value: f32 = 0,
        last_random_int_lo: i64 = 0,
        last_random_int_hi: i64 = 0,
        get_value: f64 = 0,
        last_get_name: []const u8 = "",
        last_set_name: []const u8 = "",
        last_set_value: f64 = 0,
        walkable: bool = false,
        last_walkable_col: i32 = 0,
        last_walkable_row: i32 = 0,

        fn isValid(ctx: *anyopaque, handle: u64) bool {
            _ = handle;
            return fromOpaque(ctx).valid;
        }
        fn position(ctx: *anyopaque, handle: u64) ?core.Vec3 {
            _ = handle;
            return fromOpaque(ctx).pos;
        }
        fn now(ctx: *anyopaque) f64 {
            return fromOpaque(ctx).t;
        }
        fn get(ctx: *anyopaque, handle: u64, name: []const u8) ?f64 {
            _ = handle;
            const self = fromOpaque(ctx);
            self.last_get_name = name;
            return self.get_value;
        }
        fn set(ctx: *anyopaque, handle: u64, name: []const u8, value: f64) void {
            _ = handle;
            const self = fromOpaque(ctx);
            self.last_set_name = name;
            self.last_set_value = value;
        }
        fn setVelocity(ctx: *anyopaque, handle: u64, v: core.Vec3) void {
            _ = handle;
            fromOpaque(ctx).last_vel = v;
        }
        fn setPosition(ctx: *anyopaque, handle: u64, pos: core.Vec3) void {
            _ = handle;
            fromOpaque(ctx).last_pos = pos;
        }
        fn despawn(ctx: *anyopaque, handle: u64) void {
            fromOpaque(ctx).last_despawned = handle;
        }
        fn spawn(ctx: *anyopaque, name: []const u8, pos: core.Vec3) u64 {
            const self = fromOpaque(ctx);
            self.last_spawn_name = name;
            self.last_spawn_pos = pos;
            return 77;
        }
        fn timerAfter(ctx: *anyopaque, ref: i32, delay: f32) u64 {
            const self = fromOpaque(ctx);
            self.last_ref = ref;
            self.last_delay = delay;
            return 88;
        }
        fn timerEvery(ctx: *anyopaque, ref: i32, interval: f32) u64 {
            const self = fromOpaque(ctx);
            self.last_ref = ref;
            self.last_delay = interval;
            return 99;
        }
        fn timerCancel(ctx: *anyopaque, handle: u64) void {
            fromOpaque(ctx).last_cancel = handle;
        }
        fn random(ctx: *anyopaque) f32 {
            return fromOpaque(ctx).random_value;
        }
        fn randomInt(ctx: *anyopaque, lo: i64, hi: i64) i64 {
            const self = fromOpaque(ctx);
            self.last_random_int_lo = lo;
            self.last_random_int_hi = hi;
            return lo;
        }
        fn isWalkable(ctx: *anyopaque, col: i32, row: i32) bool {
            const self = fromOpaque(ctx);
            self.last_walkable_col = col;
            self.last_walkable_row = row;
            return self.walkable;
        }
        fn fromOpaque(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        const vtable: Host.VTable = .{
            .is_valid = isValid,
            .position = position,
            .now = now,
            .get = get,
            .set = set,
            .set_velocity = setVelocity,
            .set_position = setPosition,
            .despawn = despawn,
            .spawn = spawn,
            .timer_after = timerAfter,
            .timer_every = timerEvery,
            .timer_cancel = timerCancel,
            .random = random,
            .random_int = randomInt,
            .is_walkable = isWalkable,
        };
    };

    var fake: Fake = .{ .valid = true, .pos = .{ .x = 1, .y = 2, .z = 3 }, .t = 0.5, .random_value = 0.25, .get_value = 12.5 };
    const host: Host = .{ .ctx = &fake, .vtable = &Fake.vtable };

    try testing.expect(host.isValid(0));
    try testing.expect(host.position(0).?.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(f64, 0.5), host.now());

    try testing.expectEqual(@as(?f64, 12.5), host.get(1, "score"));
    try testing.expectEqualStrings("score", fake.last_get_name);
    host.set(1, "energy", 7.5);
    try testing.expectEqualStrings("energy", fake.last_set_name);
    try testing.expectEqual(@as(f64, 7.5), fake.last_set_value);

    host.setVelocity(0, .{ .x = 4, .y = 5, .z = 6 });
    try testing.expect(fake.last_vel.approxEql(.{ .x = 4, .y = 5, .z = 6 }, 1e-6));
    host.setPosition(0, .{ .x = 1, .y = 2, .z = 3 });
    try testing.expect(fake.last_pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    host.despawn(42);
    try testing.expectEqual(@as(u64, 42), fake.last_despawned);
    try testing.expectEqual(@as(u64, 77), host.spawn("segment", .{ .x = 7, .y = 8, .z = 9 }));
    try testing.expectEqualStrings("segment", fake.last_spawn_name);
    try testing.expect(fake.last_spawn_pos.approxEql(.{ .x = 7, .y = 8, .z = 9 }, 1e-6));
    try testing.expectEqual(@as(u64, 99), host.timerEvery(5, 0.15));
    try testing.expectEqual(@as(i32, 5), fake.last_ref);
    host.timerCancel(99);
    try testing.expectEqual(@as(u64, 99), fake.last_cancel);
    try testing.expectEqual(@as(f32, 0.25), host.random());
    try testing.expectEqual(@as(i64, 3), host.randomInt(3, 8));
    try testing.expectEqual(@as(i64, 3), fake.last_random_int_lo);
    try testing.expectEqual(@as(i64, 8), fake.last_random_int_hi);

    fake.walkable = true;
    try testing.expect(host.isWalkable(2, 5));
    try testing.expectEqual(@as(i32, 2), fake.last_walkable_col);
    try testing.expectEqual(@as(i32, 5), fake.last_walkable_row);
}
