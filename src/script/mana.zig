//! The `mana` Lua API table (ADR 0003 §2) — the single global every sandboxed
//! script `_ENV` receives (`lua.zig`'s `State.pushSandboxEnv` installs it).
//! Compiled only under `-Denable-lua`.
//!
//! Over the ~500-line soft limit by design: this file IS the whole ADR 0003 §2
//! surface — one small `zlua.wrap` shim per `mana.*` member, registered in one
//! `pushManaTable`, with each member's behavior test beside it. Splitting the table
//! across files would scatter the single versioned API and its shape test for no
//! gain; it grows only when an ADR adds a member (ADR 0021 §5 added `key_down`; ADR
//! 0040 §2 added `action_down`/`action_axis`/`action_vector`; ADR 0041 §1 added
//! `capture_input`/`cancel_capture`).
//!
//! Members that need no live Sim — `version`, `log` — are implemented directly.
//! The live-Sim members reach the world/clock/command-buffer/RNG through the ADR
//! 0015 host seam (`host.zig`): the engine installs a `Host` on the owning `State`
//! for the duration of each event dispatch, and these accessors call through it.
//! Wired: the reads `is_valid`, `position`, `now`, `get` (named data components, ADR
//! 0024), `random`, `random_int` (ADR 0022, issue #47), `is_walkable` (the scene
//! tilemap's walkability grid, ADR 0035), `key_down` (the raw-device held-state
//! keyboard poll, ADR 0021 §5 / ADR 0040 §2), and the deferred mutations `set` (named
//! data components, ADR 0024), `set_velocity`, `set_position`, `despawn`, `spawn`
//! (queued on the buffer, applied at the next flush — never a mid-dispatch world
//! mutation). `is_valid` prefers the host when present (authoritative live-world
//! check) and falls back to this `State`'s own `handle.Registry` when no Sim is
//! dispatching, so its pre-seam behavior and tests still hold; mutations with no host
//! installed are dropped (`spawn` returns an invalid handle); reads (`get`/`position`/
//! `now`/`random`/`random_int`/`is_walkable`/`key_down`) return nil/0/lo/false with no
//! host installed (the same graceful degradation). Timers `after`/`every`/`cancel`
//! (ADR 0019) reference the Lua callback in the registry and schedule it on the
//! engine's wheel through the host, firing host-live in the dispatch phase.
//!
//! With `key_down` (raw device) plus the device-agnostic `action_down`/`action_axis`/
//! `action_vector` (ADR 0040 §2, resolved engine-side against the borrowed action map),
//! this table is the ADR 0003 §2 `mana` v1 surface as amended by ADR 0035 and ADR 0040.
//! The action *polls* live here; the matching `on_action` edge *event* is dispatched by
//! `lua.zig`'s `dispatchAction` (driven by the engine's per-tick action diff, ADR 0040
//! §2).
//!
//! `capture_input`/`cancel_capture` (ADR 0041 §1, issue #235) arm/disarm the
//! "press a key to bind it" primitive: the armed-action flag lives on
//! `script_runtime.zig`'s `LuaRuntime` (reached here through the same host seam as
//! every other mutation), and `src/engine/ui_dispatch.zig`'s `UiInput.keyEdge`/
//! `padButtonEdge` peek/clear it on the next qualifying physical press edge,
//! dispatching `on_input_captured` (`lua.zig`'s `dispatchInputCaptured`) — mirroring
//! how the `on_action` edge event above is dispatched outside this table. Digital
//! sources only in v1 (a key or gamepad-button press; analog is deferred, §1.1).
//! The surface stays additive, so `mana.version` remains `1` (ADR 0003 §5).

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const core_mod = @import("core");
const handle = @import("handle.zig");
const host_mod = @import("host.zig");

pub const Handle = handle.Handle;
/// The opaque UI-widget handle kind (ADR 0039 §2), re-exported so `lua.zig`'s
/// `on_click`/`on_focus`/`on_activate` dispatch can pack a widget reference without
/// importing `handle.zig` directly — the same way `Handle` is surfaced for entities.
pub const WidgetHandle = handle.WidgetHandle;
pub const Registry = handle.Registry;
pub const Host = host_mod.Host;

/// `mana.version` (ADR 0003 §5): the integer API version this build provides.
/// Additive-only within a version; any surface change (new/changed function,
/// changed handle representation) needs its own ADR, and a breaking change
/// bumps this.
pub const version: i64 = 1;

/// Push a fresh `mana` table (ADR 0003 §2) onto the Lua stack. `entities` is the
/// owning `State`'s handle registry (the `is_valid` fallback); `host` is a pointer
/// to that `State`'s optional `Host` slot (ADR 0015), which the engine sets around
/// each dispatch. Both pointers are captured as light-userdata closure upvalues, so
/// both must outlive every script `_ENV` built from this table — true for a
/// `State`'s lifetime (one per Sim, ADR 0003 §8), whose address is required to stay
/// stable. Called once per fresh `_ENV` by `State.pushSandboxEnv`.
pub fn pushManaTable(l: *Lua, entities: *const Registry, host: *const ?Host) void {
    l.newTable();

    l.pushInteger(version);
    l.setField(-2, "version");

    l.pushFunction(zlua.wrap(manaLog));
    l.setField(-2, "log");

    // is_valid: upvalue 1 = host slot (authoritative when a Sim is dispatching),
    // upvalue 2 = the registry fallback (used before/without host wiring).
    l.pushLightUserdata(@ptrCast(host));
    l.pushLightUserdata(@ptrCast(entities));
    l.pushClosure(zlua.wrap(manaIsValid), 2);
    l.setField(-2, "is_valid");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaPosition), 1);
    l.setField(-2, "position");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaNow), 1);
    l.setField(-2, "now");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaSetVelocity), 1);
    l.setField(-2, "set_velocity");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaSetPosition), 1);
    l.setField(-2, "set_position");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaDespawn), 1);
    l.setField(-2, "despawn");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaSpawn), 1);
    l.setField(-2, "spawn");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaEvery), 1);
    l.setField(-2, "every");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaAfter), 1);
    l.setField(-2, "after");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaCancel), 1);
    l.setField(-2, "cancel");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaRandom), 1);
    l.setField(-2, "random");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaRandomInt), 1);
    l.setField(-2, "random_int");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaGet), 1);
    l.setField(-2, "get");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaSet), 1);
    l.setField(-2, "set");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaIsWalkable), 1);
    l.setField(-2, "is_walkable");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaKeyDown), 1);
    l.setField(-2, "key_down");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaActionDown), 1);
    l.setField(-2, "action_down");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaActionAxis), 1);
    l.setField(-2, "action_axis");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaActionVector), 1);
    l.setField(-2, "action_vector");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaCaptureInput), 1);
    l.setField(-2, "capture_input");

    l.pushLightUserdata(@ptrCast(host));
    l.pushClosure(zlua.wrap(manaCancelCapture), 1);
    l.setField(-2, "cancel_capture");
}

/// Read a `*const ?Host` back from closure upvalue `idx` (a light-userdata pointer
/// `pushManaTable` installed). Proof of `unreachable`: every closure here is created
/// by `pushManaTable` with the host slot as a light-userdata upvalue at this index,
/// so the pointer is always present and always a `*const ?Host`.
fn hostSlot(l: *Lua, idx: i32) *const ?Host {
    const ptr = l.toPointer(idx) orelse unreachable;
    return @ptrCast(@alignCast(ptr));
}

/// `mana.log(level, msg)` (ADR 0003 §2): routes to the same engine-side log
/// sink `print` uses (never raw stdout), with an explicit level. `level` is
/// one of the Lua strings `"info"`, `"warn"`, `"error"` — ADR 0003's
/// `.info`/`.warn`/`.error` notation is Zig-enum-literal shorthand, not valid
/// Lua syntax, so this is the literal string encoding of that "enum-like
/// literal" for actual Lua callers. `msg` is stringified the way `print`
/// stringifies its arguments (`__tostring` included), so a script may pass any
/// value, not only a literal string.
fn manaLog(l: *Lua) !i32 {
    const level = l.checkString(1);
    const msg = l.toStringEx(2);
    defer l.pop(1); // toStringEx pushed a copy; drop it once read.

    const scope = std.log.scoped(.script);
    if (std.mem.eql(u8, level, "info")) {
        scope.info("{s}", .{msg});
    } else if (std.mem.eql(u8, level, "warn")) {
        scope.warn("{s}", .{msg});
    } else if (std.mem.eql(u8, level, "error")) {
        scope.err("{s}", .{msg});
    } else {
        l.argError(1, "expected \"info\", \"warn\", or \"error\"");
    }
    return 0;
}

/// `mana.is_valid(h)` (ADR 0003 §2, §4): `false` for a stale (despawned) or forged
/// handle — a generation mismatch or an out-of-range index — rather than ever
/// touching freed memory. When a `Host` is installed (a Sim is dispatching), it is
/// the authority: validity is checked against the live world. Otherwise this falls
/// back to the `State`-local `Registry` (upvalue 2), preserving pre-seam behavior.
fn manaIsValid(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| {
        l.pushBoolean(h.isValid(raw));
        return 1;
    }
    // No live host: consult this State's own generation table (upvalue 2). Proof of
    // `unreachable`: `pushManaTable` always installs the registry as this closure's
    // second light-userdata upvalue.
    const ptr = l.toPointer(Lua.upvalueIndex(2)) orelse unreachable;
    const entities: *const Registry = @ptrCast(@alignCast(ptr));
    l.pushBoolean(entities.isValid(Handle.unpack(raw)));
    return 1;
}

/// `mana.position(h)` (ADR 0003 §2): the entity's world position as three numbers
/// `x, y, z`, or a single `nil` when no Sim is dispatching, the handle is stale, or
/// the entity has no `Transform`. Reads flow through the host seam (ADR 0015) —
/// immediate, never queued.
fn manaPosition(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    const h = hostSlot(l, Lua.upvalueIndex(1)).* orelse {
        l.pushNil();
        return 1;
    };
    const p = h.position(raw) orelse {
        l.pushNil();
        return 1;
    };
    l.pushNumber(p.x);
    l.pushNumber(p.y);
    l.pushNumber(p.z);
    return 3;
}

/// `mana.now()` (ADR 0003 §2): current sim time in seconds — tick-derived, never
/// wall-clock, so it is deterministic. Returns `0` when no Sim is dispatching (no
/// host installed), the same graceful degradation the other live-Sim reads use.
fn manaNow(l: *Lua) !i32 {
    const t: f64 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.now() else 0;
    l.pushNumber(t);
    return 1;
}

/// `mana.set_velocity(h, x, y, z)` (ADR 0003 §2): queue a velocity change on `h`,
/// applied at the next flush (deferred — never a mid-dispatch mutation). A stale
/// handle is dropped at flush; with no Sim dispatching the call is a no-op. `x/y/z`
/// are world units per second. Returns nothing (fire-and-forget).
fn manaSetVelocity(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    const x: f32 = @floatCast(l.checkNumber(2));
    const y: f32 = @floatCast(l.checkNumber(3));
    const z: f32 = @floatCast(l.checkNumber(4));
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.setVelocity(raw, .{ .x = x, .y = y, .z = z });
    return 0;
}

/// `mana.set_position(h, x, y, z)` (ADR 0020): queue a discrete position change
/// (teleport) on `h`, applied at the next flush — deferred, never a mid-dispatch
/// mutation. A stale handle is dropped at flush; with no Sim dispatching, a no-op.
/// `x/y/z` are world units. Returns nothing (fire-and-forget).
fn manaSetPosition(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    const x: f32 = @floatCast(l.checkNumber(2));
    const y: f32 = @floatCast(l.checkNumber(3));
    const z: f32 = @floatCast(l.checkNumber(4));
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.setPosition(raw, .{ .x = x, .y = y, .z = z });
    return 0;
}

/// `mana.despawn(h)` (ADR 0003 §2): queue a despawn of `h`, applied at the next
/// flush (deferred). A stale handle is dropped at flush; with no Sim dispatching the
/// call is a no-op. Returns nothing.
fn manaDespawn(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.despawn(raw);
    return 0;
}

/// A packed handle that is never valid (max index) — what `mana.spawn` returns when
/// it cannot reserve an entity (no Sim dispatching, or an unknown prototype). Matches
/// `ecs.Entity.none`'s layout so `mana.is_valid` reports it false.
const invalid_handle: u64 = Handle.pack(.{ .index = std.math.maxInt(u32), .generation = 0 });

/// `mana.spawn(prototype, x, y, z)` (ADR 0003 §2; ADR 0016): spawn the named
/// `prototype` at `(x, y, z)` and return its handle. The entity is reserved
/// immediately (the handle is valid at once) and its components attach at the next
/// flush (deferred). Returns an invalid handle if no Sim is dispatching or the
/// prototype name is unknown (a content bug the engine logs) — never raises for a
/// bad name, so a script can `mana.is_valid` the result.
fn manaSpawn(l: *Lua) !i32 {
    const name = l.checkString(1);
    const x: f32 = @floatCast(l.checkNumber(2));
    const y: f32 = @floatCast(l.checkNumber(3));
    const z: f32 = @floatCast(l.checkNumber(4));
    const packed_handle: u64 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h|
        h.spawn(name, .{ .x = x, .y = y, .z = z })
    else
        invalid_handle;
    l.pushInteger(@bitCast(packed_handle));
    return 1;
}

/// Shared body of `mana.after`/`every` (ADR 0003 §2; ADR 0019): reference the Lua
/// callback (arg 2) in the registry and schedule it on the engine's timer wheel via
/// the host, returning the packed timer handle. `repeating` picks one-shot vs.
/// interval. With no Sim dispatching, the ref is released and an invalid handle
/// returned (the timer could not be scheduled).
fn scheduleTimer(l: *Lua, comptime repeating: bool) !i32 {
    const seconds: f32 = @floatCast(l.checkNumber(1));
    if (l.typeOf(2) != .function) l.argError(2, "expected a function");
    l.pushValue(2); // copy the callback to the top for `ref`
    const ref = l.ref(zlua.registry_index); // refs + pops the copy
    const timer_handle: u64 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h|
        (if (repeating) h.timerEvery(ref, seconds) else h.timerAfter(ref, seconds))
    else blk: {
        l.unref(zlua.registry_index, ref); // no host: don't leak the reference
        break :blk invalid_handle;
    };
    l.pushInteger(@bitCast(timer_handle));
    return 1;
}

/// `mana.every(interval, fn)` (ADR 0003 §2): call `fn` every `interval` seconds of
/// sim time (deterministic, tick-derived). Returns a timer handle for `mana.cancel`.
fn manaEvery(l: *Lua) !i32 {
    return scheduleTimer(l, true);
}

/// `mana.after(delay, fn)` (ADR 0003 §2): call `fn` once, `delay` seconds from now.
/// Returns a timer handle for `mana.cancel`.
fn manaAfter(l: *Lua) !i32 {
    return scheduleTimer(l, false);
}

/// `mana.cancel(h)` (ADR 0003 §2): stop a timer scheduled by `after`/`every` and
/// release its callback. A stale handle (already fired one-shot, already cancelled)
/// is a no-op. With no Sim dispatching, a no-op.
fn manaCancel(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.timerCancel(raw);
    return 0;
}

/// `mana.random()` (ADR 0003 §2; ADR 0022): a uniform float in `[0, 1)` drawn from
/// the sim's seeded `core.Rng` stream, so runs are reproducible. Immediate, like
/// `position`/`now` — never deferred. Returns `0` with no Sim dispatching (the same
/// graceful degradation `mana.now` uses).
fn manaRandom(l: *Lua) !i32 {
    const v: f32 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.random() else 0;
    l.pushNumber(v);
    return 1;
}

/// `mana.random_int(lo, hi)` (ADR 0003 §2; ADR 0022): a uniform integer in the
/// inclusive `[min(lo, hi), max(lo, hi)]` drawn from the same stream — see
/// `core.Rng.intRange` for the exact, version-stable mapping and the `lo > hi`/
/// `lo == hi` behavior. Returns `lo` with no Sim dispatching.
fn manaRandomInt(l: *Lua) !i32 {
    const lo: i64 = @intCast(l.checkInteger(1));
    const hi: i64 = @intCast(l.checkInteger(2));
    const v: i64 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.randomInt(lo, hi) else lo;
    l.pushInteger(v);
    return 1;
}

/// `mana.get(h, name)` (ADR 0003 §2; ADR 0024): read entity `h`'s named scalar data
/// component `name` — an immediate read through the host seam. Returns the number, or
/// a single `nil` when no Sim is dispatching, the handle is stale, the entity has no
/// value there, or `name` is not a declared data component (an undeclared name is
/// `nil`, never a raised error, so a script can probe optimistically).
fn manaGet(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    const name = l.checkString(2);
    const h = hostSlot(l, Lua.upvalueIndex(1)).* orelse {
        l.pushNil();
        return 1;
    };
    const v = h.get(raw, name) orelse {
        l.pushNil();
        return 1;
    };
    l.pushNumber(v);
    return 1;
}

/// `mana.set(h, name, value)` (ADR 0003 §2; ADR 0024): queue a write of entity `h`'s
/// named scalar data component `name` to `value`, applied at the next flush —
/// deferred, like `set_velocity`/`set_position`. A stale handle is dropped at flush;
/// with no Sim dispatching, a no-op; an *undeclared* component name is dropped with an
/// engine warning (declare it in scene/prototype ZON first — ADR 0024). `name` is
/// borrowed for the call only (the host resolves it immediately). Returns nothing.
fn manaSet(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    const name = l.checkString(2);
    const value = l.checkNumber(3);
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.set(raw, name, value);
    return 0;
}

/// `mana.is_walkable(col, row)` (ADR 0035): read-only query over the scene tilemap's
/// walkability grid — the same grid the native `nav` pathfinder (ADR 0027) paths over
/// (`src/engine/tilemap.zig`'s `Tilemap.isWalkable`), never a parallel/mirrored copy.
/// `col`/`row` are integer grid coordinates in the tilemap's frame. Returns `false`
/// for a wall cell, a cell outside the grid, or when no Sim is dispatching (no
/// tilemap to query) — the same graceful degradation `mana.get`'s `nil` and
/// `mana.random`'s `0` use, so a script can call this unconditionally.
///
/// Lua integers are `i64`; a coordinate outside `i32` range narrows to `false` via
/// `std.math.cast` rather than a checked `@intCast` (which would panic → abort the
/// engine on a content bug, violating ADR 0003 §9). Any out-of-`i32` value is off any
/// real grid anyway, so `false` is the correct answer, not an error.
fn manaIsWalkable(l: *Lua) !i32 {
    const col = std.math.cast(i32, l.checkInteger(1)) orelse return pushFalse(l);
    const row = std.math.cast(i32, l.checkInteger(2)) orelse return pushFalse(l);
    const walkable = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.isWalkable(col, row) else false;
    l.pushBoolean(walkable);
    return 1;
}

/// Push a Lua `false` and report one return value — the `mana.is_walkable` degraded
/// answer for an out-of-`i32`-range coordinate (see `manaIsWalkable`).
fn pushFalse(l: *Lua) i32 {
    l.pushBoolean(false);
    return 1;
}

/// `mana.key_down(name) -> bool` (ADR 0021 §5; ADR 0040 §2): the raw-device
/// held-state keyboard poll — is `name` (the same `@tagName` string `on_key`
/// already uses, e.g. `"up"`, `"w"`, `"escape"`) currently held on the sim's
/// current `InputSnapshot`. It is a pure, immediate read — never queued, and never
/// part of the state hash (input is hash-excluded, ADR 0009 §4). Coexists with the
/// device-agnostic `mana.action_down`: `key_down` names a specific physical key,
/// `action_down` names an action bound to one-or-many physical inputs. Degrades to
/// `false` (never raises) for a name that is not a known key — a content typo — or
/// when no Sim is dispatching, the same graceful-degradation policy `is_walkable`
/// uses for an out-of-grid read.
fn manaKeyDown(l: *Lua) !i32 {
    const name = l.checkString(1);
    const held = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.keyDown(name) else false;
    l.pushBoolean(held);
    return 1;
}

/// `mana.action_down(name) -> bool` (ADR 0040 §2): is the device-agnostic `button`
/// action `name` held this tick — the OR of every physical source bound to it, resolved
/// engine-side against the current `InputSnapshot`. A pure, immediate read (input is
/// hash-excluded, ADR 0009 §4). Coexists with `mana.key_down`: `action_down` is
/// device-agnostic ("is this action held, by whatever is bound"), `key_down` names a
/// specific physical key. Degrades to `false` (never raises) for an unknown or
/// wrong-typed action name — a content typo, or polling an analog action as a button —
/// or when no Sim is dispatching. `name` is borrowed for the call only.
fn manaActionDown(l: *Lua) !i32 {
    const name = l.checkString(1);
    const held = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.actionDown(name) else false;
    l.pushBoolean(held);
    return 1;
}

/// `mana.action_axis(name) -> f32` (ADR 0040 §2): the `axis1d` action `name`'s value
/// this tick — already dead-zoned and clamped to `[-1, 1]` engine-side, so content
/// never re-implements analog handling. A pure, immediate read. Degrades to `0` (never
/// raises) for an unknown or wrong-typed action name, or when no Sim is dispatching.
/// `name` is borrowed for the call only.
fn manaActionAxis(l: *Lua) !i32 {
    const name = l.checkString(1);
    const v: f32 = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.actionAxis(name) else 0;
    l.pushNumber(v);
    return 1;
}

/// `mana.action_vector(name) -> x, y` (ADR 0040 §2): the `axis2d` action `name`'s value
/// this tick, as **two returns** (not a table — a per-tick poll returning a fresh Lua
/// table would heap-allocate every frame, which invariant #3 forbids; two numbers on the
/// stack allocate nothing). Follows the `mana.position(h) -> x, y, z` convention. A pure,
/// immediate read; the value is dead-zoned/clamped engine-side. Degrades to `0, 0` (never
/// raises) for an unknown or wrong-typed action name, or when no Sim is dispatching.
/// `name` is borrowed for the call only.
fn manaActionVector(l: *Lua) !i32 {
    const name = l.checkString(1);
    const v = if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.actionVector(name) else core_mod.Vec2.zero;
    l.pushNumber(v.x);
    l.pushNumber(v.y);
    return 2;
}

/// `mana.capture_input(action)` (ADR 0041 §1): arm capture for the named `action` —
/// an opaque content string (an `input.zon` action name to the engine, invariant
/// #6). While armed, the engine's UI-input layer (`ui_dispatch.UiInput`) intercepts
/// the next qualifying physical **press** edge (a key or gamepad-button press;
/// analog sources are v1-deferred, ADR 0041 §1.1) ahead of focus-nav/activate/
/// gameplay routing, delivers it via `on_input_captured({action, source})`, and
/// disarms (one-shot). Idempotent: calling this again before an edge arrives
/// replaces the pending target — the previous one is simply never delivered.
/// Touches no filesystem (ADR 0003 §7): the engine only copies `action` into its
/// own buffer; persisting an accepted binding is a later, engine-side driver (ADR
/// 0041 §4). A no-op with no Sim dispatching (nothing to arm against).
fn manaCaptureInput(l: *Lua) !i32 {
    const action = l.checkString(1);
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.captureInput(action);
    return 0;
}

/// `mana.cancel_capture()` (ADR 0041 §1): disarm capture without binding — the
/// player backed out (Escape/Back, navigated away) before a physical edge
/// qualified. A no-op if nothing is armed, or with no Sim dispatching.
fn manaCancelCapture(l: *Lua) !i32 {
    if (hostSlot(l, Lua.upvalueIndex(1)).*) |h| h.cancelCapture();
    return 0;
}

const testing = std.testing;

test "mana: table shape exposes exactly the wired members (version..despawn); version == 1" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    const t: i32 = l.getTop();

    // Exact shape: no more, no less than the members wired so far (ADR 0003 §2 —
    // see this file's module doc for the deferred rest).
    var key_count: usize = 0;
    l.pushNil();
    while (l.next(t)) {
        key_count += 1;
        l.pop(1); // drop value; keep key on the stack to advance `next`
    }
    try testing.expectEqual(@as(usize, 23), key_count);

    try testing.expectEqual(zlua.LuaType.number, l.getField(t, "version"));
    try testing.expectEqual(@as(i64, 1), try l.toInteger(-1));
    l.pop(1);
    inline for ([_][:0]const u8{ "log", "is_valid", "position", "now", "set_velocity", "set_position", "despawn", "spawn", "every", "after", "cancel", "random", "random_int", "get", "set", "is_walkable", "key_down", "action_down", "action_axis", "action_vector", "capture_input", "cancel_capture" }) |name| {
        try testing.expectEqual(zlua.LuaType.function, l.getField(t, name));
        l.pop(1);
    }
    l.pop(1); // pop table
}

test "mana.is_valid: true for a live handle, false after despawn, and for a forged index" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.setGeneration(testing.allocator, 3, 1);
    var host: ?Host = null; // no live Sim: is_valid uses the registry fallback

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    const live: i64 = @bitCast(Handle.pack(.{ .index = 3, .generation = 1 }));
    const stale: i64 = @bitCast(Handle.pack(.{ .index = 3, .generation = 0 })); // pre-bump generation
    const forged: i64 = @bitCast(Handle.pack(.{ .index = 999, .generation = 0 })); // never registered

    var buf: [256]u8 = undefined;
    const src = try std.fmt.bufPrintZ(
        &buf,
        "return mana.is_valid({d}), mana.is_valid({d}), mana.is_valid({d})",
        .{ live, stale, forged },
    );
    try l.doString(src);

    try testing.expect(l.toBoolean(-3));
    try testing.expect(!l.toBoolean(-2));
    try testing.expect(!l.toBoolean(-1));
    l.pop(3);
}

test "mana.log: accepts info/warn levels without raising, and rejects an unknown level" {
    // Deliberately does not exercise the "error" level here: Zig's default
    // test runner (`lib/compiler/test_runner.zig`) counts any `.err`-severity
    // `std.log` call as a failed test regardless of assertions, so invoking
    // the branch that calls `scope.err` would fail this test even though
    // `manaLog` behaved correctly. `info`/`warn` below already exercise the
    // identical accept-and-dispatch code path (`manaLog`'s three branches are
    // structurally identical, differing only in which `std.log` severity they
    // call); the "error" branch is covered by code review/symmetry, not by an
    // automated invocation.
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("mana.log('info', 'hello')");
    try l.doString("mana.log('warn', 42)");

    try testing.expectError(error.LuaRuntime, l.doString("mana.log('bogus', 'x')"));
}

test "mana.log: tolerates a missing msg argument without raising" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("mana.log('info')");
}

test "mana.random/random_int: no Sim dispatching degrades to 0 / lo, never raises" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.random(), mana.random_int(5, 9)");
    try testing.expectEqual(@as(f64, 0), try l.toNumber(-2));
    try testing.expectEqual(@as(i64, 5), try l.toInteger(-1));
    l.pop(2);
}

test "mana.get/set: no Sim dispatching returns nil and no-ops, never raises" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    // get degrades to nil; set is a harmless no-op that returns nothing.
    try l.doString("return mana.get(1, 'score')");
    try testing.expect(l.isNil(-1));
    l.pop(1);
    try l.doString("mana.set(1, 'score', 42)"); // must not raise with no host
}

test "mana.is_walkable: no Sim dispatching returns false, never raises" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.is_walkable(0, 0)");
    try testing.expect(!l.toBoolean(-1));
    l.pop(1);
}

/// A fake host whose `is_walkable` mimics `Tilemap.isWalkable` over a tiny 2x2
/// walkable square with a wall at (1,1) — enough to exercise `mana.is_walkable`'s
/// wiring (arg marshaling, host dispatch, return value) without `script` importing
/// `engine`'s real `Tilemap` (DAG: `script → core` only; the tilemap's own
/// walkability rules are `src/engine/tilemap.zig`'s tests). Every other accessor is
/// an `unreachable` stub — proof no test below exercises anything but `is_walkable`.
const FakeGridHost = struct {
    fn isWalkable(ctx: *anyopaque, col: i32, row: i32) bool {
        _ = ctx;
        if (col < 0 or row < 0 or col > 1 or row > 1) return false; // out of grid
        if (col == 1 and row == 1) return false; // the one wall cell
        return true;
    }
    fn isValid(ctx: *anyopaque, h: u64) bool {
        _ = ctx;
        _ = h;
        unreachable;
    }
    fn position(ctx: *anyopaque, h: u64) ?core_mod.Vec3 {
        _ = ctx;
        _ = h;
        unreachable;
    }
    fn now(ctx: *anyopaque) f64 {
        _ = ctx;
        unreachable;
    }
    fn get(ctx: *anyopaque, h: u64, name: []const u8) ?f64 {
        _ = .{ ctx, h, name };
        unreachable;
    }
    fn set(ctx: *anyopaque, h: u64, name: []const u8, value: f64) void {
        _ = .{ ctx, h, name, value };
        unreachable;
    }
    fn setVelocity(ctx: *anyopaque, h: u64, v: core_mod.Vec3) void {
        _ = .{ ctx, h, v };
        unreachable;
    }
    fn setPosition(ctx: *anyopaque, h: u64, pos: core_mod.Vec3) void {
        _ = .{ ctx, h, pos };
        unreachable;
    }
    fn despawn(ctx: *anyopaque, h: u64) void {
        _ = .{ ctx, h };
        unreachable;
    }
    fn spawn(ctx: *anyopaque, name: []const u8, pos: core_mod.Vec3) u64 {
        _ = .{ ctx, name, pos };
        unreachable;
    }
    fn timerAfter(ctx: *anyopaque, ref: i32, delay: f32) u64 {
        _ = .{ ctx, ref, delay };
        unreachable;
    }
    fn timerEvery(ctx: *anyopaque, ref: i32, interval: f32) u64 {
        _ = .{ ctx, ref, interval };
        unreachable;
    }
    fn timerCancel(ctx: *anyopaque, h: u64) void {
        _ = .{ ctx, h };
        unreachable;
    }
    fn random(ctx: *anyopaque) f32 {
        _ = ctx;
        unreachable;
    }
    fn randomInt(ctx: *anyopaque, lo: i64, hi: i64) i64 {
        _ = .{ ctx, lo, hi };
        unreachable;
    }
    fn keyDown(ctx: *anyopaque, name: []const u8) bool {
        _ = .{ ctx, name };
        unreachable;
    }
    fn actionDown(ctx: *anyopaque, name: []const u8) bool {
        _ = .{ ctx, name };
        unreachable;
    }
    fn actionAxis(ctx: *anyopaque, name: []const u8) f32 {
        _ = .{ ctx, name };
        unreachable;
    }
    fn actionVector(ctx: *anyopaque, name: []const u8) core_mod.Vec2 {
        _ = .{ ctx, name };
        unreachable;
    }
    fn captureInput(ctx: *anyopaque, name: []const u8) void {
        _ = .{ ctx, name };
        unreachable;
    }
    fn cancelCapture(ctx: *anyopaque) void {
        _ = ctx;
        unreachable;
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
        .key_down = keyDown,
        .action_down = actionDown,
        .action_axis = actionAxis,
        .action_vector = actionVector,
        .capture_input = captureInput,
        .cancel_capture = cancelCapture,
    };
};

test "mana.is_walkable: true for a walkable cell, false for a wall cell, false out of bounds" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var fake_ctx: u8 = 0; // unused by isWalkable; a valid non-null ctx pointer
    var host: ?Host = .{ .ctx = &fake_ctx, .vtable = &FakeGridHost.vtable };

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.is_walkable(0, 0), mana.is_walkable(1, 1), mana.is_walkable(-1, 0)");
    try testing.expect(l.toBoolean(-3)); // (0,0): open floor
    try testing.expect(!l.toBoolean(-2)); // (1,1): the wall
    try testing.expect(!l.toBoolean(-1)); // (-1,0): off-grid
    l.pop(3);
}

test "mana.is_walkable: an out-of-i32-range coordinate returns false, never a panic" {
    // A Lua integer (i64) past i32's range must NOT reach a checked @intCast — that
    // would abort the engine on a content bug (ADR 0003 §9). It narrows to false: any
    // such coordinate is off any real grid. (99999999999 is outside FakeGridHost's 2x2
    // walkable square anyway, so the answer is false whether or not the guard fires;
    // the point of this test is that reaching that answer never panics.)
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var fake_ctx: u8 = 0;
    var host: ?Host = .{ .ctx = &fake_ctx, .vtable = &FakeGridHost.vtable };

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    // 99999999999 (the reviewer's value) and i32-min-minus-one, on either coordinate.
    try l.doString("return mana.is_walkable(99999999999, 0), mana.is_walkable(0, -2147483649)");
    try testing.expect(!l.toBoolean(-2));
    try testing.expect(!l.toBoolean(-1));
    l.pop(2);
}

test "mana.action_down/axis/vector: no Sim dispatching degrades to false / 0 / 0,0, never raises" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.action_down('jump'), mana.action_axis('throttle'), mana.action_vector('move')");
    // action_vector returns two values, so the stack is: [down, axis, vx, vy].
    try testing.expect(!l.toBoolean(-4)); // action_down → false
    try testing.expectEqual(@as(f64, 0), try l.toNumber(-3)); // action_axis → 0
    try testing.expectEqual(@as(f64, 0), try l.toNumber(-2)); // action_vector x → 0
    try testing.expectEqual(@as(f64, 0), try l.toNumber(-1)); // action_vector y → 0
    l.pop(4);
}

test "mana.capture_input/cancel_capture: no Sim dispatching are no-ops, never raise" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("mana.capture_input('jump')");
    try l.doString("mana.cancel_capture()");
}

test "mana.key_down: no Sim dispatching returns false, never raises" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.key_down('up')");
    try testing.expect(!l.toBoolean(-1));
    l.pop(1);
}

/// A fake host whose `key_down` reports one fixed held key by name — enough to
/// exercise `mana.key_down`'s wiring (arg marshaling, host dispatch, return value)
/// without `script` importing `platform.Key` (DAG: `script → core` only; the real
/// held-key set is `platform.InputSnapshot`, resolved engine-side, ADR 0021 §5 /
/// ADR 0040 §2). Every other accessor is an `unreachable` stub — proof no test below
/// exercises anything but `key_down`.
const FakeKeyHost = struct {
    held: []const u8,

    fn keyDown(ctx: *anyopaque, name: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return std.mem.eql(u8, name, self.held);
    }
    fn isValid(ctx: *anyopaque, h: u64) bool {
        _ = .{ ctx, h };
        unreachable;
    }
    fn position(ctx: *anyopaque, h: u64) ?core_mod.Vec3 {
        _ = .{ ctx, h };
        unreachable;
    }
    fn now(ctx: *anyopaque) f64 {
        _ = ctx;
        unreachable;
    }
    fn get(ctx: *anyopaque, h: u64, name: []const u8) ?f64 {
        _ = .{ ctx, h, name };
        unreachable;
    }
    fn set(ctx: *anyopaque, h: u64, name: []const u8, value: f64) void {
        _ = .{ ctx, h, name, value };
        unreachable;
    }
    fn setVelocity(ctx: *anyopaque, h: u64, v: core_mod.Vec3) void {
        _ = .{ ctx, h, v };
        unreachable;
    }
    fn setPosition(ctx: *anyopaque, h: u64, pos: core_mod.Vec3) void {
        _ = .{ ctx, h, pos };
        unreachable;
    }
    fn despawn(ctx: *anyopaque, h: u64) void {
        _ = .{ ctx, h };
        unreachable;
    }
    fn spawn(ctx: *anyopaque, name: []const u8, pos: core_mod.Vec3) u64 {
        _ = .{ ctx, name, pos };
        unreachable;
    }
    fn timerAfter(ctx: *anyopaque, ref: i32, delay: f32) u64 {
        _ = .{ ctx, ref, delay };
        unreachable;
    }
    fn timerEvery(ctx: *anyopaque, ref: i32, interval: f32) u64 {
        _ = .{ ctx, ref, interval };
        unreachable;
    }
    fn timerCancel(ctx: *anyopaque, h: u64) void {
        _ = .{ ctx, h };
        unreachable;
    }
    fn random(ctx: *anyopaque) f32 {
        _ = ctx;
        unreachable;
    }
    fn randomInt(ctx: *anyopaque, lo: i64, hi: i64) i64 {
        _ = .{ ctx, lo, hi };
        unreachable;
    }
    fn isWalkable(ctx: *anyopaque, col: i32, row: i32) bool {
        _ = .{ ctx, col, row };
        unreachable;
    }
    fn actionDown(ctx: *anyopaque, name: []const u8) bool {
        _ = .{ ctx, name };
        unreachable;
    }
    fn actionAxis(ctx: *anyopaque, name: []const u8) f32 {
        _ = .{ ctx, name };
        unreachable;
    }
    fn actionVector(ctx: *anyopaque, name: []const u8) core_mod.Vec2 {
        _ = .{ ctx, name };
        unreachable;
    }
    fn captureInput(ctx: *anyopaque, name: []const u8) void {
        _ = .{ ctx, name };
        unreachable;
    }
    fn cancelCapture(ctx: *anyopaque) void {
        _ = ctx;
        unreachable;
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
        .key_down = keyDown,
        .action_down = actionDown,
        .action_axis = actionAxis,
        .action_vector = actionVector,
        .capture_input = captureInput,
        .cancel_capture = cancelCapture,
    };
};

test "key_down: reports held key true, released key false" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var fake: FakeKeyHost = .{ .held = "up" };
    var host: ?Host = .{ .ctx = &fake, .vtable = &FakeKeyHost.vtable };

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    try l.doString("return mana.key_down('up'), mana.key_down('down')");
    try testing.expect(l.toBoolean(-2)); // held
    try testing.expect(!l.toBoolean(-1)); // not held
    l.pop(2);
}

test "key_down: an unknown key name degrades to false rather than raising" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var fake: FakeKeyHost = .{ .held = "up" };
    var host: ?Host = .{ .ctx = &fake, .vtable = &FakeKeyHost.vtable };

    pushManaTable(l, &registry, &host);
    l.setGlobal("mana");

    // The host resolves the name against `platform.Key`; a name that is not a real
    // key (a content typo) simply never matches the held one, so this reaches the
    // same `false` a real engine-side `stringToEnum` miss would — never a raise.
    try l.doString("return mana.key_down('not_a_real_key')");
    try testing.expect(!l.toBoolean(-1));
    l.pop(1);
}
