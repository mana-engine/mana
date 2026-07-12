//! The Sim-owned bridge to the scripting port (ADR 0003 §1, §8): one script
//! runtime per Sim, holding one Lua state that loads one handler table and
//! receives dispatched Sim events. `Runtime` is comptime-selected on
//! `-Denable-lua`: the real `LuaRuntime` when Lua is compiled in, an inert
//! `NoopRuntime` otherwise. The default (no-Lua) build therefore pays nothing —
//! dispatch is a comptime no-op and the sim stays bit-identical — mirroring how
//! `gpu`/`script` gate their real backends. This is the one engine seam that may
//! reach into `script`; no Lua/handle type crosses back up (the packing stays in
//! `script`), so the "nothing above `script` sees a Lua type" invariant holds.

const std = @import("std");
const core = @import("core");
const script = @import("script");
const ecs = @import("ecs");
const event = @import("event.zig");
const command = @import("command.zig");
const prototype = @import("prototype.zig");
const World = @import("world.zig").World;

const Entity = ecs.Entity;
const Allocator = std.mem.Allocator;

/// The live-Sim state one event dispatch needs to build the host seam (ADR 0015):
/// the world + command buffer a handler's `mana` reads/mutations act on, this tick's
/// sim time, and the prototype registry `mana.spawn` resolves against. Bundled so
/// the dispatch signature stays stable as the seam grows (future slices add e.g. the
/// sim RNG here, not another positional arg). `Sim.tick` fills it each tick.
pub const DispatchCtx = struct {
    world: *World,
    commands: *command.CommandBuffer,
    gpa: Allocator,
    now_seconds: f64,
    prototypes: prototype.Registry = .{},
};

/// The Sim's script runtime: the Lua-backed one under `-Denable-lua`, else a
/// no-op with the same shape so `Sim` code is backend-agnostic.
pub const Runtime = if (script.lua_enabled) LuaRuntime else NoopRuntime;

/// The handler-table keys the engine currently dispatches (ADR 0003 §3). One
/// entry per key the circuit breaker (§9) tracks independently; grow this
/// alongside `dispatch`'s `switch` as new events gain a v1 handler key.
const HandlerKey = enum {
    on_scene_enter,
    on_spawn,
    on_collision_begin,
};

/// Consecutive errored dispatches of the *same* handler key, with no success in
/// between, that trip the circuit breaker (ADR 0003 §9: "N errors ... within a
/// window"). Chosen window rule: **consecutive errors since the last success (or
/// since the handler table was (re)loaded), no wall-clock/tick span involved** —
/// a plain counter that resets to 0 on `.ok`. This is the simplest scheme that is
/// still deterministic (same sequence of handler outcomes ⇒ same tick disables),
/// per the ADR's own requirement that the breaker not perturb the state hash.
const breaker_threshold: u32 = 8;

/// Per-handler-key circuit-breaker bookkeeping (ADR 0003 §9): a fixed-size
/// counter and a latch, no heap allocation. `loadHandlers` resets every key back
/// to this default, so a freshly (re)loaded script starts with all keys enabled.
const BreakerState = struct {
    /// Consecutive `.errored` outcomes since the last `.ok` (or since load).
    consecutive_errors: u32 = 0,
    /// Latched once `consecutive_errors` reaches `breaker_threshold`. `dispatch`
    /// skips this key from then on, exactly like a missing handler, until the
    /// next `loadHandlers`.
    disabled: bool = false,
};

/// Lua-backed runtime (only instantiated under `-Denable-lua`). Owns an optional
/// `script.lua.State`, created lazily on the first `loadHandlers`, so a Sim that
/// never loads a script never spins up an interpreter and dispatch stays a cheap
/// null check.
const LuaRuntime = struct {
    /// Created on demand by `loadHandlers`. Stored by value; its address must be
    /// stable once populated (the sandbox captures a pointer into it), which holds
    /// as long as the owning `Sim` is not moved after loading a script.
    state: ?script.lua.State = null,

    /// Per-handler-key circuit-breaker state (ADR 0003 §9). Fixed-size (one slot
    /// per `HandlerKey`), zero heap allocation; reset wholesale by `loadHandlers`.
    breakers: std.EnumArray(HandlerKey, BreakerState) = .initFill(.{}),

    /// Tear down the interpreter, if any. `gpa` is unused (the `State` owns the
    /// allocator it was built with); taken for signature parity with `NoopRuntime`.
    pub fn deinit(self: *LuaRuntime, gpa: Allocator) void {
        _ = gpa;
        if (self.state) |*s| s.deinit();
        self.* = .{};
    }

    /// Load `source` as this Sim's single handler table (ADR 0003 §1), creating
    /// the Lua state on first use. `gpa` backs the interpreter and must outlive the
    /// runtime. Errors propagate from `State.init`/`loadHandlerTable` (bad Lua, a
    /// non-table return, or allocation failure). A successful (re)load resets
    /// every handler key's circuit-breaker state (§9): the old script's failures
    /// never carry over to the newly loaded one, hot-reloaded or not.
    pub fn loadHandlers(self: *LuaRuntime, gpa: Allocator, source: [:0]const u8) !void {
        if (self.state == null) self.state = try script.lua.State.init(gpa);
        try self.state.?.loadHandlerTable(source);
        self.breakers = .initFill(.{});
    }

    /// Engine-side backing for the host seam (ADR 0015): the concrete vtable the
    /// `mana` accessors call through, over the live `world`, the sim's `commands`
    /// buffer, and this tick's `now_seconds`. Lives inside `LuaRuntime` (only
    /// instantiated under `-Denable-lua`), so it names `script.lua.Host` only where
    /// that type exists. Reads resolve immediately (a stale handle degrades to
    /// null/false, never a deref of freed storage); mutations queue on `commands`
    /// and apply at the next flush (ADR 0003 §2). An allocation failure while
    /// queuing sets `oom`, which `dispatch` turns into a tick-aborting error — OOM
    /// is never a content bug, so it is not surfaced to the script.
    const HostCtx = struct {
        world: *World,
        commands: *command.CommandBuffer,
        gpa: Allocator,
        now_seconds: f64,
        prototypes: prototype.Registry,
        oom: bool = false,

        fn fromDc(dc: DispatchCtx) HostCtx {
            return .{
                .world = dc.world,
                .commands = dc.commands,
                .gpa = dc.gpa,
                .now_seconds = dc.now_seconds,
                .prototypes = dc.prototypes,
            };
        }
        fn cast(ctx: *anyopaque) *HostCtx {
            return @ptrCast(@alignCast(ctx));
        }
        fn isValid(ctx: *anyopaque, handle: u64) bool {
            return cast(ctx).world.isValid(Entity.unpack(handle));
        }
        fn position(ctx: *anyopaque, handle: u64) ?core.Vec3 {
            const t = cast(ctx).world.getTransform(Entity.unpack(handle)) orelse return null;
            return t.pos;
        }
        fn now(ctx: *anyopaque) f64 {
            return cast(ctx).now_seconds;
        }
        fn setVelocity(ctx: *anyopaque, handle: u64, v: core.Vec3) void {
            const hc = cast(ctx);
            hc.commands.setVelocity(hc.gpa, Entity.unpack(handle), .{ .v = v }) catch {
                hc.oom = true;
            };
        }
        fn despawn(ctx: *anyopaque, handle: u64) void {
            const hc = cast(ctx);
            hc.commands.despawn(hc.gpa, Entity.unpack(handle)) catch {
                hc.oom = true;
            };
        }
        fn spawn(ctx: *anyopaque, name: []const u8, pos: core.Vec3) u64 {
            const hc = cast(ctx);
            const proto = hc.prototypes.lookup(name) orelse {
                std.log.scoped(.script).warn("mana.spawn: unknown prototype '{s}'", .{name});
                return Entity.none.pack();
            };
            const e = hc.commands.spawn(hc.gpa, hc.world, prototype.bundleAt(proto, pos)) catch {
                hc.oom = true;
                return Entity.none.pack();
            };
            return e.pack();
        }
        const vtable: script.lua.Host.VTable = .{
            .is_valid = isValid,
            .position = position,
            .now = now,
            .set_velocity = setVelocity,
            .despawn = despawn,
            .spawn = spawn,
        };
    };

    /// Forward one Sim event to the matching handler-table key (ADR 0003 §3),
    /// installing the live host seam (ADR 0015) for the duration of the call so the
    /// handler's `mana` reads see `world` at `now_seconds` and its `mana` mutations
    /// queue on `commands`. A no-op if no script is loaded, the event has no v1
    /// handler key, or the key's circuit breaker has disabled it (§9).
    ///
    /// The handler runs inside a command-buffer transaction (ADR 0003 §9): if it
    /// throws, every mutation it queued this call is rolled back so a failed handler
    /// leaves no trace — exactly the guarantee `Sim` gives an erroring system. A
    /// handler error is otherwise caught and logged, never propagated; only an
    /// allocation failure (a queued mutation hitting OOM, never a content bug)
    /// propagates and aborts the tick.
    pub fn dispatch(self: *LuaRuntime, ev: event.Event, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;

        // Map the event to its v1 handler key; events without one (despawn: no
        // on_death/on_hit engine event exists yet, ADR 0003 §3) dispatch nothing.
        const key: HandlerKey = switch (ev) {
            .spawned => .on_spawn,
            .collision_begin => .on_collision_begin,
            .despawned => return,
        };
        if (self.isDisabled(key)) return;

        var host_ctx: HostCtx = .fromDc(dc);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null); // the borrowed ctx must not outlive this dispatch

        // §9 transaction: discard this handler's queued mutations if it throws.
        const mark = dc.commands.mark();
        const outcome = switch (ev) {
            .spawned => |e| s.dispatchSpawn(e.index, e.generation),
            .collision_begin => |c| s.dispatchCollisionBegin(
                c.a.index,
                c.a.generation,
                c.b.index,
                c.b.generation,
                0, // the collision event carries no contact normal yet (ADR 0008)
                0,
            ),
            .despawned => unreachable, // returned above: no handler key
        };
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory; // a queued mutation hit OOM
        self.report(key, s, outcome);
    }

    /// Dispatch the per-scene bootstrap event `on_scene_enter(ev = { scene })`
    /// (ADR 0017) with the host live, so the handler can query the freshly-loaded
    /// scene and wire timers/rules. Same transaction + OOM discipline as `dispatch`.
    /// A no-op if no script is loaded, the key is absent, or its breaker tripped.
    pub fn dispatchSceneEnter(self: *LuaRuntime, scene_name: []const u8, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(.on_scene_enter)) return;

        var host_ctx: HostCtx = .fromDc(dc);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = s.dispatchSceneEnter(scene_name);
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(.on_scene_enter, s, outcome);
    }

    /// Read integer field `key` off the loaded handler table, or null. Lets the
    /// engine (and tests) observe handler-declared scalars without a Lua type
    /// escaping `script`.
    pub fn handlerFieldInt(self: *LuaRuntime, key: [:0]const u8) ?i64 {
        const s = if (self.state) |*st| st else return null;
        return s.handlerFieldInt(key);
    }

    /// True once `key`'s circuit breaker has tripped (ADR 0003 §9): `dispatch`
    /// skips it silently from this point on, until the next `loadHandlers`.
    /// Test/observability seam; the engine itself never needs to ask.
    pub fn isDisabled(self: *const LuaRuntime, key: HandlerKey) bool {
        return self.breakers.get(key).disabled;
    }

    /// Log-and-continue plus circuit-breaker bookkeeping (ADR 0003 §9) for one
    /// dispatch outcome: an error is always logged at `.err` with the Lua
    /// message (unconditional, matching the pre-existing log-and-continue
    /// behavior); `updateBreaker` then decides whether this was also the tick
    /// that tripped the breaker, in which case a second, distinct `.warn` fires
    /// exactly once. `ok`/`no_handler` never log.
    fn report(self: *LuaRuntime, key: HandlerKey, s: *script.lua.State, outcome: script.lua.State.DispatchOutcome) void {
        if (outcome == .errored) {
            std.log.scoped(.script).err("{s} handler errored: {s}", .{ @tagName(key), s.lastError() });
        }
        if (self.updateBreaker(key, outcome) == .just_disabled) {
            std.log.scoped(.script).warn(
                "{s} handler disabled after {d} consecutive errors (circuit breaker, ADR 0003 §9)",
                .{ @tagName(key), breaker_threshold },
            );
        }
    }

    /// The effect one dispatch outcome had on a handler key's circuit breaker.
    /// Returned rather than logged directly (mirroring `script.lua.State.
    /// DispatchOutcome`, see `src/script/CLAUDE.md`) so the count/latch
    /// transition is unit-testable without emitting a `std.log` call — the Zig
    /// test runner counts any `.err`-severity call as a failed test, and
    /// `report` above is what actually logs.
    const BreakerUpdate = enum {
        /// `.ok`/`.no_handler`, or an `.errored` outcome on an already-disabled
        /// key (unreachable via `dispatch`, which gates on `isDisabled` first;
        /// guarded here anyway so the state machine is total).
        unaffected,
        /// `.errored`, count grew, but the key is still enabled.
        errored,
        /// `.errored` and the count just reached `breaker_threshold` on this
        /// call: the key is now disabled. Fires at most once per (re)load.
        just_disabled,
    };

    /// Update `key`'s circuit-breaker bookkeeping for one dispatch `outcome`
    /// (ADR 0003 §9): a success resets the consecutive-error count to 0; an
    /// error increments it and, the first time it reaches `breaker_threshold`,
    /// latches `disabled`. Pure state transition, no I/O — see `BreakerUpdate`.
    fn updateBreaker(self: *LuaRuntime, key: HandlerKey, outcome: script.lua.State.DispatchOutcome) BreakerUpdate {
        const breaker = self.breakers.getPtr(key);
        switch (outcome) {
            .no_handler => return .unaffected,
            .ok => {
                breaker.consecutive_errors = 0;
                return .unaffected;
            },
            .errored => {
                if (breaker.disabled) return .unaffected;
                breaker.consecutive_errors += 1;
                if (breaker.consecutive_errors >= breaker_threshold) {
                    breaker.disabled = true;
                    return .just_disabled;
                }
                return .errored;
            },
        }
    }
};

/// The default runtime when Lua is not compiled in: every method is an inert
/// no-op so `Sim` needs no `-Denable-lua` conditionals. Zero-sized, so it adds no
/// state to `Sim` and the optimizer elides the dispatch calls entirely.
const NoopRuntime = struct {
    pub fn deinit(self: *NoopRuntime, gpa: Allocator) void {
        _ = self;
        _ = gpa;
    }

    pub fn loadHandlers(self: *NoopRuntime, gpa: Allocator, source: [:0]const u8) !void {
        _ = self;
        _ = gpa;
        _ = source;
    }

    pub fn dispatch(self: *NoopRuntime, ev: event.Event, dc: DispatchCtx) Allocator.Error!void {
        _ = self;
        _ = ev;
        _ = dc;
    }

    pub fn dispatchSceneEnter(self: *NoopRuntime, scene_name: []const u8, dc: DispatchCtx) Allocator.Error!void {
        _ = self;
        _ = scene_name;
        _ = dc;
    }

    pub fn handlerFieldInt(self: *NoopRuntime, key: [:0]const u8) ?i64 {
        _ = self;
        _ = key;
        return null;
    }
};

// --- Circuit breaker (ADR 0003 §9) tests (`-Denable-lua`) -------------------
//
// These drive `updateBreaker` directly with synthetic outcomes rather than
// dispatching a real erroring Lua handler through `report`: `report` logs at
// `.err` on every `.errored` outcome (the pre-existing log-and-continue
// behavior), and the Zig test runner counts any `.err`-severity `std.log` call
// as a failed test regardless of assertions (see `src/script/CLAUDE.md`'s note
// on `DispatchOutcome`, which exists for the same reason). `updateBreaker`
// itself never logs, so it is the log-free seam these tests exercise.

test "circuit breaker: a handler disabled after breaker_threshold consecutive errors stops being dispatched" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var rt: LuaRuntime = .{};
    defer rt.deinit(std.testing.allocator);
    try rt.loadHandlers(std.testing.allocator,
        \\local t = { spawns = 0 }
        \\function t.on_spawn(self) t.spawns = t.spawns + 1 end
        \\return t
    );

    for (0..breaker_threshold - 1) |_| {
        try std.testing.expectEqual(LuaRuntime.BreakerUpdate.errored, rt.updateBreaker(.on_spawn, .errored));
    }
    try std.testing.expect(!rt.isDisabled(.on_spawn));
    try std.testing.expectEqual(LuaRuntime.BreakerUpdate.just_disabled, rt.updateBreaker(.on_spawn, .errored));
    try std.testing.expect(rt.isDisabled(.on_spawn));

    // With `on_spawn` disabled, `dispatch` must skip the (otherwise working)
    // handler entirely: the spawn counter stays at 0, proving it never ran.
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var commands: command.CommandBuffer = .{};
    defer commands.deinit(std.testing.allocator);
    try rt.dispatch(.{ .spawned = .{ .index = 1, .generation = 0 } }, .{
        .world = &world,
        .commands = &commands,
        .gpa = std.testing.allocator,
        .now_seconds = 0,
    });
    try std.testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("spawns").?);
}

test "circuit breaker: disabling one handler key leaves a different key unaffected" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var rt: LuaRuntime = .{};
    defer rt.deinit(std.testing.allocator);
    try rt.loadHandlers(std.testing.allocator,
        \\local t = { collisions = 0 }
        \\function t.on_collision_begin(self, ev) t.collisions = t.collisions + 1 end
        \\return t
    );

    for (0..breaker_threshold) |_| _ = rt.updateBreaker(.on_spawn, .errored);
    try std.testing.expect(rt.isDisabled(.on_spawn));
    try std.testing.expect(!rt.isDisabled(.on_collision_begin));

    // The healthy on_collision_begin handler still dispatches normally.
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var commands: command.CommandBuffer = .{};
    defer commands.deinit(std.testing.allocator);
    try rt.dispatch(.{ .collision_begin = .{
        .a = .{ .index = 1, .generation = 0 },
        .b = .{ .index = 2, .generation = 0 },
    } }, .{
        .world = &world,
        .commands = &commands,
        .gpa = std.testing.allocator,
        .now_seconds = 0,
    });
    try std.testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("collisions").?);
}

test "circuit breaker: loadHandlers reload re-enables a disabled key and resets its count" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var rt: LuaRuntime = .{};
    defer rt.deinit(std.testing.allocator);
    try rt.loadHandlers(std.testing.allocator, "return {}");

    for (0..breaker_threshold) |_| _ = rt.updateBreaker(.on_spawn, .errored);
    try std.testing.expect(rt.isDisabled(.on_spawn));

    // A fresh load resets both the latch and the count: one error short of the
    // threshold must not immediately re-disable the key.
    try rt.loadHandlers(std.testing.allocator, "return {}");
    try std.testing.expect(!rt.isDisabled(.on_spawn));
    for (0..breaker_threshold - 1) |_| {
        try std.testing.expectEqual(LuaRuntime.BreakerUpdate.errored, rt.updateBreaker(.on_spawn, .errored));
    }
    try std.testing.expect(!rt.isDisabled(.on_spawn));
}

test "circuit breaker: a success resets the consecutive-error count so the breaker does not latch early" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var rt: LuaRuntime = .{};
    defer rt.deinit(std.testing.allocator);
    try rt.loadHandlers(std.testing.allocator, "return {}");

    // One short of the threshold, then a success: the count must zero out, so
    // these 7 errors leave the key enabled.
    for (0..breaker_threshold - 1) |_| _ = rt.updateBreaker(.on_spawn, .errored);
    try std.testing.expect(!rt.isDisabled(.on_spawn));
    try std.testing.expectEqual(LuaRuntime.BreakerUpdate.unaffected, rt.updateBreaker(.on_spawn, .ok));

    // A fresh run of threshold-1 errors after the reset must still not trip it —
    // proving the earlier 7 did not carry over past the success.
    for (0..breaker_threshold - 1) |_| {
        try std.testing.expectEqual(LuaRuntime.BreakerUpdate.errored, rt.updateBreaker(.on_spawn, .errored));
    }
    try std.testing.expect(!rt.isDisabled(.on_spawn));

    // Only the 8th consecutive error *since the reset* disables the key.
    try std.testing.expectEqual(LuaRuntime.BreakerUpdate.just_disabled, rt.updateBreaker(.on_spawn, .errored));
    try std.testing.expect(rt.isDisabled(.on_spawn));
}

test "circuit breaker: the disable transition fires exactly once until the next reload" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var rt: LuaRuntime = .{};
    defer rt.deinit(std.testing.allocator);
    try rt.loadHandlers(std.testing.allocator, "return {}");

    var disables: u32 = 0;
    for (0..breaker_threshold + 5) |_| {
        if (rt.updateBreaker(.on_spawn, .errored) == .just_disabled) disables += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), disables);
}
