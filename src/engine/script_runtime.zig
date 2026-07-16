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
const tracy = core.tracy;
const script = @import("script");
const ecs = @import("ecs");
const event = @import("event.zig");
const command = @import("command.zig");
const prototype = @import("prototype.zig");
const timer = @import("timer.zig");
const World = @import("world.zig").World;
const Tilemap = @import("tilemap.zig").Tilemap;
const action_map = @import("action_map.zig");
const ActionMap = action_map.ActionMap;
const platform = @import("platform");

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
    /// The Sim's timer wheel, so `mana.after`/`every` can schedule Lua callbacks on
    /// it and `advanceTimers` can fire them host-live (ADR 0019).
    timers: *timer.Timers,
    /// The Sim's seeded RNG stream, so `mana.random`/`random_int` draw from it
    /// (ADR 0022, issue #47) instead of a fresh/nondeterministic source.
    rng: *core.Rng,
    /// The scene's grid level (ADR 0026/0027), or null if the sim has none, so
    /// `mana.is_walkable` (ADR 0035) can query the same walkability grid the native
    /// `nav` pathfinder paths over. Mirrors `Sim.tilemap`/`Context.tilemap`.
    tilemap: ?*const Tilemap = null,
    /// This tick's `InputSnapshot` (ADR 0009 §3/§4), so `mana.key_down` (ADR 0021 §5
    /// / ADR 0040 §2) can poll the same held-key set native systems already read via
    /// `Context.input`. Mirrors `Sim.input`; hash-excluded like all input (ADR 0009).
    input: platform.InputSnapshot = .{},
    /// The sim's borrowed action-binding table (ADR 0040 §3), or null if the package
    /// declares none, so the device-agnostic `mana.action_down`/`action_axis`/
    /// `action_vector` polls (ADR 0040 §2) can resolve action names against `input`.
    /// Mirrors `Sim.action_map`; read-only config, never part of the state hash.
    action_map: ?*const ActionMap = null,
};

/// The Sim's script runtime: the Lua-backed one under `-Denable-lua`, else a
/// no-op with the same shape so `Sim` code is backend-agnostic.
pub const Runtime = if (script.lua_enabled) LuaRuntime else NoopRuntime;

/// The handler-table keys the engine currently dispatches (ADR 0003 §3). One
/// entry per key the circuit breaker (§9) tracks independently; grow this
/// alongside `dispatch`'s `switch` as new events gain a v1 handler key.
const HandlerKey = enum {
    on_scene_enter,
    on_key,
    /// Device-agnostic action edges (ADR 0040 §2), diffed and dispatched exactly like
    /// `on_key` but keyed by content action name; its own circuit-breaker slot (§9).
    on_action,
    /// Capture-mode delivery (ADR 0041 §1): fires once per armed capture, on the
    /// first qualifying physical press edge (a key or gamepad-button press);
    /// its own circuit-breaker slot (§9).
    on_input_captured,
    /// UI input events (ADR 0039): each is a distinct circuit-breaker slot (§9), so a
    /// broken `on_click` never disables `on_focus`/`on_activate` and vice versa.
    on_click,
    on_focus,
    on_activate,
    on_spawn,
    on_collision_begin,
    /// Lua timer callbacks (ADR 0019) — one breaker slot for all of them, so an
    /// error-storm from a repeating timer is disabled like any handler key.
    timer,
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

    /// Live Lua-timer records (ADR 0019), each heap-allocated so its address is
    /// stable while the timer wheel holds a closure pointing at it. Owns the Lua
    /// callback reference until the timer fires (one-shot), is cancelled, or the
    /// runtime tears down.
    lua_timers: std.ArrayList(*LuaTimerRecord) = .empty,

    /// The action name currently armed for capture (ADR 0041 §1), gpa-owned (a
    /// dupe of whatever `mana.capture_input` was called with), or null when
    /// disarmed. Set via `armCapture` (reached through the host seam); peeked and
    /// cleared by `ui_dispatch.UiInput.keyEdge`/`padButtonEdge` on the next
    /// qualifying physical press edge, or cleared without binding by
    /// `mana.cancel_capture` (`clearCapture`). UI-layer state, hash-excluded (ADR
    /// 0041 §5) — never part of `World.stateHash`, exactly like the focus/hit-test
    /// state `ui_dispatch` already carries.
    capture_armed: ?[]const u8 = null,

    /// One scheduled Lua timer: the callback reference plus the wheel handle it maps
    /// to (for `mana.cancel`) and whether it repeats (a one-shot retires itself when
    /// it fires). The wheel closure's `context` is a `*LuaTimerRecord`.
    const LuaTimerRecord = struct {
        runtime: *LuaRuntime,
        ref: i32,
        repeating: bool,
        handle: timer.Handle,
    };

    /// Tear down the interpreter and release every outstanding timer reference and
    /// record (ADR 0019) — before the `State` (whose Lua owns the refs) is destroyed.
    pub fn deinit(self: *LuaRuntime, gpa: Allocator) void {
        if (self.state) |*s| {
            for (self.lua_timers.items) |rec| s.releaseTimerRef(rec.ref);
        }
        for (self.lua_timers.items) |rec| gpa.destroy(rec);
        self.lua_timers.deinit(gpa);
        if (self.state) |*s| s.deinit();
        self.clearCapture(gpa);
        self.* = .{};
    }

    /// Arm capture for `action` (ADR 0041 §1 `mana.capture_input`, reached through
    /// `HostCtx.captureInput`): dupe it into engine-owned memory so it outlives this
    /// call across ticks. Idempotent — the dupe happens *before* any previously
    /// armed target is freed, so an allocation failure leaves the previous arm
    /// intact rather than silently disarming.
    pub fn armCapture(self: *LuaRuntime, gpa: Allocator, action: []const u8) Allocator.Error!void {
        const dup = try gpa.dupe(u8, action);
        self.clearCapture(gpa);
        self.capture_armed = dup;
    }

    /// Disarm capture (ADR 0041 §1): free the armed buffer, if any, and clear it.
    /// Used both by `mana.cancel_capture` (disarm without binding) and by
    /// `ui_dispatch` right after a qualifying edge delivers `on_input_captured`
    /// (the one-shot consume). A no-op when nothing is armed.
    pub fn clearCapture(self: *LuaRuntime, gpa: Allocator) void {
        if (self.capture_armed) |a| gpa.free(a);
        self.capture_armed = null;
    }

    /// The action currently armed for capture, or null when disarmed (ADR 0041
    /// §1) — `ui_dispatch` peeks this on every qualifying physical press edge.
    pub fn armedCapture(self: *const LuaRuntime) ?[]const u8 {
        return self.capture_armed;
    }

    /// Release a timer record's reference, unlink it, and free it (ADR 0019). Called
    /// when a one-shot fires or a timer is cancelled.
    fn retireTimer(self: *LuaRuntime, gpa: Allocator, rec: *LuaTimerRecord) void {
        if (self.state) |*s| s.releaseTimerRef(rec.ref);
        for (self.lua_timers.items, 0..) |r, i| {
            if (r == rec) {
                _ = self.lua_timers.swapRemove(i);
                break;
            }
        }
        gpa.destroy(rec);
    }

    /// Retire the timer record for wheel `handle`, if any (the `mana.cancel` path).
    fn retireByHandle(self: *LuaRuntime, gpa: Allocator, handle: timer.Handle) void {
        for (self.lua_timers.items) |rec| {
            if (rec.handle.index == handle.index and rec.handle.generation == handle.generation) {
                self.retireTimer(gpa, rec);
                return;
            }
        }
    }

    /// The wheel closure that fires a Lua timer (ADR 0019). Runs host-live (the host
    /// is installed by `advanceTimers` around the wheel advance), inside the §9
    /// command-buffer transaction: a throwing callback is rolled back and reported,
    /// only OOM (recorded on the host ctx) aborts. A one-shot retires afterward.
    fn fireLuaTimer(context: *anyopaque, world: *World) void {
        _ = world;
        const rec: *LuaTimerRecord = @ptrCast(@alignCast(context));
        const self = rec.runtime;
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(.timer)) return;
        // The host installed around the advance carries the command buffer + oom flag.
        const host = s.host orelse return;
        const host_ctx: *HostCtx = @ptrCast(@alignCast(host.ctx));

        const z = tracy.zone(@src(), "script.timer");
        defer z.end();
        const mark = host_ctx.commands.mark();
        const outcome = s.invokeTimerRef(rec.ref);
        if (outcome == .errored) host_ctx.commands.rollback(host_ctx.world, mark) catch {
            host_ctx.oom = true;
        };
        self.report(.timer, s, outcome);
        if (!rec.repeating) self.retireTimer(host_ctx.gpa, rec);
    }

    /// Load `source` as this Sim's single handler table (ADR 0003 §1), creating
    /// the Lua state on first use. `gpa` backs the interpreter and must outlive the
    /// runtime. Errors propagate from `State.init`/`loadHandlerTable` (bad Lua, a
    /// non-table return, or allocation failure). A successful (re)load resets
    /// every handler key's circuit-breaker state (§9): the old script's failures
    /// never carry over to the newly loaded one, hot-reloaded or not. Also disarms
    /// any pending capture (ADR 0041 §1): a fresh handler table may not even define
    /// `on_input_captured` the same way, so an arm from the *previous* script must
    /// not silently deliver into the new one.
    pub fn loadHandlers(self: *LuaRuntime, gpa: Allocator, source: [:0]const u8) !void {
        if (self.state == null) self.state = try script.lua.State.init(gpa);
        try self.state.?.loadHandlerTable(source);
        self.breakers = .initFill(.{});
        self.clearCapture(gpa);
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
        timers: *timer.Timers,
        runtime: *LuaRuntime,
        rng: *core.Rng,
        tilemap: ?*const Tilemap,
        input: platform.InputSnapshot,
        action_map: ?*const ActionMap,
        oom: bool = false,

        fn init(dc: DispatchCtx, runtime: *LuaRuntime) HostCtx {
            return .{
                .world = dc.world,
                .commands = dc.commands,
                .gpa = dc.gpa,
                .now_seconds = dc.now_seconds,
                .prototypes = dc.prototypes,
                .timers = dc.timers,
                .runtime = runtime,
                .rng = dc.rng,
                .tilemap = dc.tilemap,
                .input = dc.input,
                .action_map = dc.action_map,
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
        /// `mana.get` (ADR 0024): immediate read of a named scalar data component.
        /// Resolves `name` to a column against the live world; an undeclared name or
        /// stale handle reads `null` (never a deref of freed storage).
        fn get(ctx: *anyopaque, handle: u64, name: []const u8) ?f64 {
            const hc = cast(ctx);
            const col = hc.world.dataColumn(name) orelse return null;
            return hc.world.getData(Entity.unpack(handle), col);
        }
        /// `mana.set` (ADR 0024): queue a named scalar data-component write on
        /// `commands`, applied at the next flush. An undeclared component is a content
        /// bug — logged and dropped, never a crash or a mid-dispatch rollback over a
        /// typo (ADR 0024). Allocation failure sets `oom`, aborting the tick.
        fn set(ctx: *anyopaque, handle: u64, name: []const u8, value: f64) void {
            const hc = cast(ctx);
            const col = hc.world.dataColumn(name) orelse {
                std.log.scoped(.script).warn(
                    "mana.set: unknown data component '{s}' (declare it in scene/prototype ZON, ADR 0024)",
                    .{name},
                );
                return;
            };
            hc.commands.setData(hc.gpa, Entity.unpack(handle), col, value) catch {
                hc.oom = true;
            };
        }
        fn setVelocity(ctx: *anyopaque, handle: u64, v: core.Vec3) void {
            const hc = cast(ctx);
            hc.commands.setVelocity(hc.gpa, Entity.unpack(handle), .{ .v = v }) catch {
                hc.oom = true;
            };
        }
        fn setPosition(ctx: *anyopaque, handle: u64, pos: core.Vec3) void {
            const hc = cast(ctx);
            hc.commands.setTransform(hc.gpa, Entity.unpack(handle), .{ .pos = pos }) catch {
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
        fn timerEvery(ctx: *anyopaque, ref: i32, interval: f32) u64 {
            return cast(ctx).scheduleTimer(ref, interval, true);
        }
        fn timerAfter(ctx: *anyopaque, ref: i32, delay: f32) u64 {
            return cast(ctx).scheduleTimer(ref, delay, false);
        }
        /// Reference-owning schedule: on any allocation failure the ref is released
        /// (never leaked) and an invalid handle returned; `oom` aborts the tick.
        fn scheduleTimer(hc: *HostCtx, ref: i32, seconds: f32, repeating: bool) u64 {
            const rec = hc.gpa.create(LuaTimerRecord) catch return hc.timerOom(ref);
            rec.* = .{ .runtime = hc.runtime, .ref = ref, .repeating = repeating, .handle = undefined };
            hc.runtime.lua_timers.append(hc.gpa, rec) catch {
                hc.gpa.destroy(rec);
                return hc.timerOom(ref);
            };
            const cb: timer.Callback = .{ .closure = .{ .context = rec, .func = fireLuaTimer } };
            const handle = (if (repeating)
                hc.timers.every(hc.gpa, seconds, cb)
            else
                hc.timers.after(hc.gpa, seconds, cb)) catch {
                _ = hc.runtime.lua_timers.pop();
                hc.gpa.destroy(rec);
                return hc.timerOom(ref);
            };
            rec.handle = handle;
            return handle.pack();
        }
        /// Record OOM, release the (unscheduled) callback reference, and hand back an
        /// invalid handle. Keeps `scheduleTimer` honest on the failure path.
        fn timerOom(hc: *HostCtx, ref: i32) u64 {
            hc.oom = true;
            if (hc.runtime.state) |*s| s.releaseTimerRef(ref);
            return timer.Handle.pack(.{ .index = std.math.maxInt(u32), .generation = 0 });
        }
        fn timerCancel(ctx: *anyopaque, handle: u64) void {
            const hc = cast(ctx);
            const h = timer.Handle.unpack(handle);
            hc.timers.cancel(h);
            hc.runtime.retireByHandle(hc.gpa, h);
        }
        /// `mana.random` (ADR 0022): an immediate read of the sim's seeded RNG
        /// stream, never queued — reading advances the stream itself, which is the
        /// whole point (a fresh draw each call).
        fn random(ctx: *anyopaque) f32 {
            return cast(ctx).rng.float01();
        }
        /// `mana.random_int` (ADR 0022): see `core.Rng.intRange` for the exact,
        /// version-stable mapping.
        fn randomInt(ctx: *anyopaque, lo: i64, hi: i64) i64 {
            return cast(ctx).rng.intRange(lo, hi);
        }
        /// `mana.is_walkable` (ADR 0035): an immediate read of the sim's tilemap —
        /// `false` when the sim has none (no scene tilemap loaded), matching
        /// `Tilemap.isWalkable`'s own off-grid/wall `false`. Queries the same grid
        /// the native `nav` pathfinder paths over; never a parallel/mirrored copy.
        fn isWalkable(ctx: *anyopaque, col: i32, row: i32) bool {
            const tm = cast(ctx).tilemap orelse return false;
            return tm.isWalkable(col, row);
        }
        /// `mana.key_down` (ADR 0021 §5 / ADR 0040 §2): an immediate read of this
        /// tick's `InputSnapshot.keys` — the same held-state set native systems poll
        /// via `Context.input` (`src/engine/input.zig`). `name` is the `@tagName`
        /// scheme `on_key` already uses; a name that is not a known `platform.Key`
        /// (a content typo) resolves to `false` via `stringToEnum`, never an error.
        fn keyDown(ctx: *anyopaque, name: []const u8) bool {
            const key = std.meta.stringToEnum(platform.Key, name) orelse return false;
            return cast(ctx).input.keys.contains(key);
        }
        /// `mana.action_down` (ADR 0040 §2): the device-agnostic held poll — resolves
        /// action `name` against this tick's `InputSnapshot` via the pure resolver
        /// (`action_map.buttonHeld`, the OR of every bound source). `false` when the sim
        /// has no action map, or the name is unknown/wrong-typed (the resolver's neutral
        /// value). Immediate, like `key_down`.
        fn actionDown(ctx: *anyopaque, name: []const u8) bool {
            const hc = cast(ctx);
            const map = hc.action_map orelse return false;
            return action_map.buttonHeld(map.*, hc.input, name);
        }
        /// `mana.action_axis` (ADR 0040 §2): the `axis1d` value poll — dead-zoned and
        /// clamped engine-side by `action_map.axis1d`. `0` with no action map or an
        /// unknown/wrong-typed name.
        fn actionAxis(ctx: *anyopaque, name: []const u8) f32 {
            const hc = cast(ctx);
            const map = hc.action_map orelse return 0;
            return action_map.axis1d(map.*, hc.input, name);
        }
        /// `mana.action_vector` (ADR 0040 §2): the `axis2d` value poll — the
        /// `(x, y)` from `action_map.axis2d` (dead-zoned/clamped engine-side). Zero
        /// vector with no action map or an unknown/wrong-typed name.
        fn actionVector(ctx: *anyopaque, name: []const u8) core.Vec2 {
            const hc = cast(ctx);
            const map = hc.action_map orelse return core.Vec2.zero;
            return action_map.axis2d(map.*, hc.input, name);
        }
        /// `mana.capture_input` (ADR 0041 §1): arm `hc.runtime`'s capture state.
        /// An allocation failure (duping `name`) records `oom`, aborting the tick —
        /// never surfaced to the script (OOM is never a content bug).
        fn captureInput(ctx: *anyopaque, name: []const u8) void {
            const hc = cast(ctx);
            hc.runtime.armCapture(hc.gpa, name) catch {
                hc.oom = true;
            };
        }
        /// `mana.cancel_capture` (ADR 0041 §1): disarm without binding.
        fn cancelCapture(ctx: *anyopaque) void {
            const hc = cast(ctx);
            hc.runtime.clearCapture(hc.gpa);
        }
        const vtable: script.lua.Host.VTable = .{
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
            .key_down = keyDown,
            .action_down = actionDown,
            .action_axis = actionAxis,
            .action_vector = actionVector,
            .capture_input = captureInput,
            .cancel_capture = cancelCapture,
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

        const z = tracy.zone(@src(), "script.dispatch");
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
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

        const z = tracy.zone(@src(), "script.scene_enter");
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = s.dispatchSceneEnter(scene_name);
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(.on_scene_enter, s, outcome);
    }

    /// Dispatch a keyboard edge `on_key(ev = { key, pressed })` (ADR 0021) host-live:
    /// `key_name` is the neutral `@tagName` of the pressed/released key, `pressed`
    /// distinguishes press from release. Same transaction + OOM discipline as the
    /// other dispatch paths. A no-op if no script is loaded, the key is absent, or the
    /// breaker tripped.
    pub fn dispatchKey(self: *LuaRuntime, key_name: []const u8, pressed: bool, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(.on_key)) return;

        const z = tracy.zone(@src(), "script.on_key");
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = s.dispatchKey(key_name, pressed);
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(.on_key, s, outcome);
    }

    /// Dispatch a device-agnostic action edge `on_action(ev = { action, pressed })`
    /// (ADR 0040 §2) host-live: `action_name` is the content-declared action name whose
    /// OR-combined held-state transitioned this tick, `pressed` distinguishes the down
    /// edge from the up edge. Mirrors `dispatchKey` exactly — same host-install, §9
    /// command-buffer transaction, and circuit-breaker discipline. A no-op if no script
    /// is loaded, the `on_action` handler is absent, or its breaker tripped.
    pub fn dispatchAction(self: *LuaRuntime, action_name: []const u8, pressed: bool, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(.on_action)) return;

        const z = tracy.zone(@src(), "script.on_action");
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = s.dispatchAction(action_name, pressed);
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(.on_action, s, outcome);
    }

    /// Dispatch a capture delivery `on_input_captured(ev = { action, source })`
    /// (ADR 0041 §1) host-live: `action_name` is the action capture was armed for,
    /// `source_name` the device-neutral binding-descriptor string naming the
    /// physical input that qualified (see `ui_dispatch.zig` for how the two source
    /// vocabularies — bare key names, `"pad_"`-prefixed button names — are built).
    /// Mirrors `dispatchAction` exactly — same host-install, §9 command-buffer
    /// transaction, and circuit-breaker discipline. A no-op if no script is loaded,
    /// the handler is absent, or its breaker tripped.
    pub fn dispatchInputCaptured(self: *LuaRuntime, action_name: []const u8, source_name: []const u8, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(.on_input_captured)) return;

        const z = tracy.zone(@src(), "script.on_input_captured");
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = s.dispatchInputCaptured(action_name, source_name);
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(.on_input_captured, s, outcome);
    }

    /// Dispatch a UI pointer click `on_click(ev = { widget, id, x, y })` (ADR 0039 §1)
    /// host-live: `index`/`generation` are the engine-assigned widget-handle fields, `id`
    /// the hit widget's authored name, `x`/`y` the press point in screen pixels. Same
    /// host-install + §9 command-buffer-transaction + circuit-breaker discipline as
    /// `dispatchKey`. A no-op if no script is loaded, the key is absent, or its breaker
    /// tripped. A handler's gameplay mutations queue on `commands` as usual — the click
    /// itself is cosmetic and never enters the state hash (ADR 0039 §4).
    pub fn dispatchClick(self: *LuaRuntime, index: u32, generation: u32, id: []const u8, x: f32, y: f32, dc: DispatchCtx) Allocator.Error!void {
        try self.dispatchUi(.on_click, index, generation, id, x, y, dc);
    }

    /// Dispatch a UI focus entry `on_focus(ev = { widget, id })` (ADR 0039 §1) host-live.
    /// Same discipline as `dispatchClick`; carries no pointer coordinate (nav-driven).
    pub fn dispatchFocus(self: *LuaRuntime, index: u32, generation: u32, id: []const u8, dc: DispatchCtx) Allocator.Error!void {
        try self.dispatchUi(.on_focus, index, generation, id, 0, 0, dc);
    }

    /// Dispatch a UI activation `on_activate(ev = { widget, id })` (ADR 0039 §1)
    /// host-live. Same discipline as `dispatchClick`; carries no pointer coordinate.
    pub fn dispatchActivate(self: *LuaRuntime, index: u32, generation: u32, id: []const u8, dc: DispatchCtx) Allocator.Error!void {
        try self.dispatchUi(.on_activate, index, generation, id, 0, 0, dc);
    }

    /// Shared host-live dispatch for the three ADR 0039 UI events: install the host
    /// seam, run the handler inside a §9 command-buffer transaction (rolled back if it
    /// throws), and record the outcome on `key`'s circuit breaker. `x`/`y` are ignored
    /// for `on_focus`/`on_activate` (their `State` dispatch omits the coordinate fields).
    fn dispatchUi(self: *LuaRuntime, comptime key: HandlerKey, index: u32, generation: u32, id: []const u8, x: f32, y: f32, dc: DispatchCtx) Allocator.Error!void {
        const s = if (self.state) |*st| st else return;
        if (self.isDisabled(key)) return;

        const z = tracy.zone(@src(), "script." ++ @tagName(key));
        defer z.end();
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);

        const mark = dc.commands.mark();
        const outcome = switch (key) {
            .on_click => s.dispatchClick(index, generation, id, x, y),
            .on_focus => s.dispatchFocus(index, generation, id),
            .on_activate => s.dispatchActivate(index, generation, id),
            else => comptime unreachable, // dispatchUi is only called for the three UI keys
        };
        if (outcome == .errored) try dc.commands.rollback(dc.world, mark);
        if (host_ctx.oom) return error.OutOfMemory;
        self.report(key, s, outcome);
    }

    /// Advance the timer wheel by `dt` (ADR 0019), firing due timers — Lua callbacks
    /// among them run host-live: the host is installed for the duration so a timer's
    /// `mana` calls resolve. Native timers fire regardless of the host. Only OOM from
    /// a Lua timer (a queued mutation or a scheduling failure) propagates and aborts
    /// the tick; a throwing Lua timer is caught per-callback (see `fireLuaTimer`).
    pub fn advanceTimers(self: *LuaRuntime, dc: DispatchCtx, dt: f32) Allocator.Error!void {
        const s = if (self.state) |*st| st else {
            try dc.timers.advance(dc.gpa, dc.world, dt);
            return;
        };
        var host_ctx: HostCtx = .init(dc, self);
        s.setHost(.{ .ctx = &host_ctx, .vtable = &HostCtx.vtable });
        defer s.setHost(null);
        try dc.timers.advance(dc.gpa, dc.world, dt);
        if (host_ctx.oom) return error.OutOfMemory;
    }

    /// Read integer field `key` off the loaded handler table, or null. Lets the
    /// engine (and tests) observe handler-declared scalars without a Lua type
    /// escaping `script`.
    pub fn handlerFieldInt(self: *LuaRuntime, key: [:0]const u8) ?i64 {
        const s = if (self.state) |*st| st else return null;
        return s.handlerFieldInt(key);
    }

    /// Read table-valued handler field `key`'s string→string entries, or null when no
    /// script is loaded or the field is absent/not a table — the table-valued sibling
    /// to `handlerFieldInt` (ADR 0041 §4), for an engine-side driver that persists a
    /// *set* of values the script proposed rather than one scalar (#135's pattern
    /// generalised). Additive engine→state read only: no `mana` member is added, so
    /// ADR 0003 §5's version gate is untouched.
    ///
    /// The result and every string in it are `gpa`-owned copies (never a borrow into
    /// Lua memory, so a later collection cannot invalidate them) — free with
    /// `freeStrMap`. Order is unspecified (Lua hash order); sort before writing to a
    /// file. Errors: `OutOfMemory` only.
    pub fn handlerFieldStrMap(self: *LuaRuntime, gpa: Allocator, key: [:0]const u8) Allocator.Error!?[]const script.StrPair {
        const s = if (self.state) |*st| st else return null;
        return s.handlerFieldStrMap(gpa, key);
    }

    /// Replace table-valued handler field `key` with exactly `pairs` — the write twin of
    /// `handlerFieldStrMap` (ADR 0041 §4 amendment, issue #247), for a driver that must
    /// tell the script what it persisted on the script's behalf (a script cannot read
    /// the file itself, ADR 0003 §7). Still engine→state only: no `mana` member is
    /// added, so ADR 0003 §5's version gate is untouched.
    ///
    /// A no-op when no script is loaded. The field is replaced wholesale, never merged.
    /// `pairs` and its strings are borrowed for the call only (Lua copies them).
    pub fn setHandlerFieldStrMap(self: *LuaRuntime, key: [:0]const u8, pairs: []const script.StrPair) void {
        const s = if (self.state) |*st| st else return;
        s.setHandlerFieldStrMap(key, pairs);
    }

    /// Free a `handlerFieldStrMap` result (its strings and the slice). `gpa` must be
    /// the allocator that produced it.
    pub fn freeStrMap(gpa: Allocator, pairs: []const script.StrPair) void {
        script.lua.State.freeStrMap(gpa, pairs);
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

    pub fn dispatchKey(self: *NoopRuntime, key_name: []const u8, pressed: bool, dc: DispatchCtx) Allocator.Error!void {
        _ = self;
        _ = key_name;
        _ = pressed;
        _ = dc;
    }

    pub fn dispatchAction(self: *NoopRuntime, action_name: []const u8, pressed: bool, dc: DispatchCtx) Allocator.Error!void {
        _ = .{ self, action_name, pressed, dc };
    }

    /// Always disarmed under the default (no-Lua) build: there is no `mana` surface
    /// to arm capture from, so `ui_dispatch` always sees "nothing armed" and never
    /// claims an edge for capture — every existing (no-Lua) build behaves exactly
    /// as before ADR 0041 existed.
    pub fn armedCapture(self: *const NoopRuntime) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn clearCapture(self: *NoopRuntime, gpa: Allocator) void {
        _ = .{ self, gpa };
    }

    pub fn dispatchInputCaptured(self: *NoopRuntime, action_name: []const u8, source_name: []const u8, dc: DispatchCtx) Allocator.Error!void {
        _ = .{ self, action_name, source_name, dc };
    }

    pub fn dispatchClick(self: *NoopRuntime, index: u32, generation: u32, id: []const u8, x: f32, y: f32, dc: DispatchCtx) Allocator.Error!void {
        _ = .{ self, index, generation, id, x, y, dc };
    }

    pub fn dispatchFocus(self: *NoopRuntime, index: u32, generation: u32, id: []const u8, dc: DispatchCtx) Allocator.Error!void {
        _ = .{ self, index, generation, id, dc };
    }

    pub fn dispatchActivate(self: *NoopRuntime, index: u32, generation: u32, id: []const u8, dc: DispatchCtx) Allocator.Error!void {
        _ = .{ self, index, generation, id, dc };
    }

    pub fn advanceTimers(self: *NoopRuntime, dc: DispatchCtx, dt: f32) Allocator.Error!void {
        _ = self;
        try dc.timers.advance(dc.gpa, dc.world, dt);
    }

    pub fn handlerFieldInt(self: *NoopRuntime, key: [:0]const u8) ?i64 {
        _ = self;
        _ = key;
        return null;
    }

    /// Always null under the default (no-Lua) build: there is no handler table to
    /// read, so an engine-side persistence driver (ADR 0041 §4) sees "the package
    /// proposes nothing" and never writes — the same inert shape `handlerFieldInt`
    /// already has.
    pub fn handlerFieldStrMap(self: *NoopRuntime, gpa: Allocator, key: [:0]const u8) Allocator.Error!?[]const script.StrPair {
        _ = .{ self, gpa, key };
        return null;
    }

    /// A no-op under the default (no-Lua) build: there is no handler table to write
    /// into, so a driver seeding the script with the loaded override (ADR 0041 §4
    /// amendment) simply has no one to tell — inert exactly like its read twin.
    pub fn setHandlerFieldStrMap(self: *NoopRuntime, key: [:0]const u8, pairs: []const script.StrPair) void {
        _ = .{ self, key, pairs };
    }

    /// A no-op: `handlerFieldStrMap` above never allocates, so there is nothing to free.
    pub fn freeStrMap(gpa: Allocator, pairs: []const script.StrPair) void {
        _ = .{ gpa, pairs };
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
    var timers: timer.Timers = .{};
    defer timers.deinit(std.testing.allocator);
    var rng: core.Rng = core.Rng.init(0);
    try rt.dispatch(.{ .spawned = .{ .index = 1, .generation = 0 } }, .{
        .world = &world,
        .commands = &commands,
        .gpa = std.testing.allocator,
        .now_seconds = 0,
        .timers = &timers,
        .rng = &rng,
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
    var timers: timer.Timers = .{};
    defer timers.deinit(std.testing.allocator);
    var rng: core.Rng = core.Rng.init(0);
    try rt.dispatch(.{ .collision_begin = .{
        .a = .{ .index = 1, .generation = 0 },
        .b = .{ .index = 2, .generation = 0 },
    } }, .{
        .world = &world,
        .commands = &commands,
        .gpa = std.testing.allocator,
        .now_seconds = 0,
        .timers = &timers,
        .rng = &rng,
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
