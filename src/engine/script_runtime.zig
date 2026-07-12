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
const script = @import("script");
const ecs = @import("ecs");
const event = @import("event.zig");

const Entity = ecs.Entity;
const Allocator = std.mem.Allocator;

/// The Sim's script runtime: the Lua-backed one under `-Denable-lua`, else a
/// no-op with the same shape so `Sim` code is backend-agnostic.
pub const Runtime = if (script.lua_enabled) LuaRuntime else NoopRuntime;

/// The handler-table keys the engine currently dispatches (ADR 0003 §3). One
/// entry per key the circuit breaker (§9) tracks independently; grow this
/// alongside `dispatch`'s `switch` as new events gain a v1 handler key.
const HandlerKey = enum {
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

    /// Forward one Sim event to the matching handler-table key (ADR 0003 §3). A
    /// no-op if no script is loaded, the key is absent, or the key's circuit
    /// breaker has disabled it (§9); a handler error is caught and logged, never
    /// propagated.
    pub fn dispatch(self: *LuaRuntime, ev: event.Event) void {
        const s = if (self.state) |*st| st else return;
        switch (ev) {
            .spawned => |e| {
                if (self.isDisabled(.on_spawn)) return;
                self.report(.on_spawn, s, s.dispatchSpawn(e.index, e.generation));
            },
            .collision_begin => |c| {
                if (self.isDisabled(.on_collision_begin)) return;
                self.report(.on_collision_begin, s, s.dispatchCollisionBegin(
                    c.a.index,
                    c.a.generation,
                    c.b.index,
                    c.b.generation,
                    0, // the collision event carries no contact normal yet (ADR 0008)
                    0,
                ));
            },
            // No v1 handler key exists for despawn (ADR 0003 §3): on_death/on_hit
            // are gated on engine events that do not exist yet.
            .despawned => {},
        }
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

    pub fn dispatch(self: *NoopRuntime, ev: event.Event) void {
        _ = self;
        _ = ev;
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
    rt.dispatch(.{ .spawned = .{ .index = 1, .generation = 0 } });
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
    rt.dispatch(.{ .collision_begin = .{
        .a = .{ .index = 1, .generation = 0 },
        .b = .{ .index = 2, .generation = 0 },
    } });
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
