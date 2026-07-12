//! The `mana` Lua API table (ADR 0003 §2) — the single global every sandboxed
//! script `_ENV` receives (`lua.zig`'s `State.pushSandboxEnv` installs it).
//! Compiled only under `-Denable-lua`.
//!
//! Members that need no live Sim — `version`, `log` — are implemented directly.
//! The live-Sim members reach the world/clock/command-buffer through the ADR 0015
//! host seam (`host.zig`): the engine installs a `Host` on the owning `State` for
//! the duration of each event dispatch, and these accessors call through it. Wired
//! so far (issue #5): the reads `is_valid`, `position`, `now`, and the deferred
//! mutations `set_velocity`, `set_position`, `despawn`, `spawn` (queued on the buffer,
//! applied at the next flush — never a mid-dispatch world mutation). `is_valid`
//! prefers the host when present (authoritative live-world check) and falls back to
//! this `State`'s own `handle.Registry` when no Sim is dispatching, so its pre-seam
//! behavior and tests still hold; mutations with no host installed are dropped
//! (`spawn` returns an invalid handle). Timers `after`/`every`/`cancel` (ADR 0019)
//! reference the Lua callback in the registry and schedule it on the engine's wheel
//! through the host, firing host-live in the dispatch phase.
//!
//! The remaining §2 members — `set` (needs a data-component store), `get`, and
//! `random`/`random_int` (seeded `core.Rng`) — land as additive host-vtable entries
//! in follow-up slices. Do not add stub/fake
//! behavior for them; an absent `mana` key is the honest, checkable signal that a
//! member is not implemented yet, matching how a missing event-handler key means
//! "no handler" elsewhere in ADR 0003.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const handle = @import("handle.zig");
const host_mod = @import("host.zig");

pub const Handle = handle.Handle;
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

const testing = std.testing;

test "mana: table shape exposes exactly the wired members (version..despawn); version == 1" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var host: ?Host = null;

    pushManaTable(l, &registry, &host);
    const t: i32 = l.getTop();

    // Exact shape: no more, no less than the seven members wired so far
    // (ADR 0003 §2 — see this file's module doc for the deferred rest).
    var key_count: usize = 0;
    l.pushNil();
    while (l.next(t)) {
        key_count += 1;
        l.pop(1); // drop value; keep key on the stack to advance `next`
    }
    try testing.expectEqual(@as(usize, 12), key_count);

    try testing.expectEqual(zlua.LuaType.number, l.getField(t, "version"));
    try testing.expectEqual(@as(i64, 1), try l.toInteger(-1));
    l.pop(1);
    inline for ([_][:0]const u8{ "log", "is_valid", "position", "now", "set_velocity", "set_position", "despawn", "spawn", "every", "after", "cancel" }) |name| {
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
