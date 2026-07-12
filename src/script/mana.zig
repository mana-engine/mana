//! The `mana` Lua API table (ADR 0003 §2) — the single global every sandboxed
//! script `_ENV` receives (`lua.zig`'s `State.pushSandboxEnv` installs it).
//! Compiled only under `-Denable-lua`.
//!
//! This implements exactly the subset of ADR 0003 §2 that needs no live
//! Sim/World: `version`, `log`, and `is_valid` (backed by `handle.Registry`,
//! this `State`'s own generation table). The rest of §2's v1 surface —
//! `position`, `set_velocity`, `get`, `set`, `spawn`, `despawn`, `after`,
//! `every`, `cancel`, `now`, `random`, `random_int` — reads or mutates live
//! component data, the sim clock, the sim's seeded `core.Rng`, a spawn/despawn
//! command buffer, or the timer wheel, none of which `script` can reach today:
//! nothing in `engine` holds a `script.State`, and nothing here holds a `Sim`
//! (the module import DAG has `script` depend on `core` only). Adding those
//! needs an engine → script wiring task first — deliberately out of scope here
//! (see the issue this module was built for). Do not add stub/fake behavior
//! for them; an absent key is the honest, checkable signal that they are not
//! implemented yet, matching how a missing event handler key means "no
//! handler" elsewhere in ADR 0003.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const handle = @import("handle.zig");

pub const Handle = handle.Handle;
pub const Registry = handle.Registry;

/// `mana.version` (ADR 0003 §5): the integer API version this build provides.
/// Additive-only within a version; any surface change (new/changed function,
/// changed handle representation) needs its own ADR, and a breaking change
/// bumps this.
pub const version: i64 = 1;

/// Push a fresh `mana` table (ADR 0003 §2) onto the Lua stack. `entities` is
/// the owning `State`'s handle registry; `is_valid` captures a light-userdata
/// pointer to it as a closure upvalue, so it must outlive every script `_ENV`
/// built from this table (true for a `State`'s lifetime — one per Sim, ADR
/// 0003 §8). Called once per fresh `_ENV` by `State.pushSandboxEnv`.
pub fn pushManaTable(l: *Lua, entities: *const Registry) void {
    l.newTable();

    l.pushInteger(version);
    l.setField(-2, "version");

    l.pushFunction(zlua.wrap(manaLog));
    l.setField(-2, "log");

    l.pushLightUserdata(@ptrCast(entities));
    l.pushClosure(zlua.wrap(manaIsValid), 1);
    l.setField(-2, "is_valid");
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

/// `mana.is_valid(h)` (ADR 0003 §2, §4): `false` for a stale (despawned) or
/// forged handle — a generation mismatch or an out-of-range index — rather
/// than ever touching freed memory. Reads the registry captured as this
/// closure's sole upvalue (see `pushManaTable`).
fn manaIsValid(l: *Lua) !i32 {
    const raw: u64 = @bitCast(try l.toInteger(1));
    // Proof: `pushManaTable` always creates this closure with exactly one
    // light-userdata upvalue pointing at a live `Registry`, so upvalue 1 is
    // never anything else.
    const ptr = l.toPointer(Lua.upvalueIndex(1)) orelse unreachable;
    const entities: *const Registry = @ptrCast(@alignCast(ptr));
    l.pushBoolean(entities.isValid(Handle.unpack(raw)));
    return 1;
}

const testing = std.testing;

test "mana: table shape exposes exactly version, log, is_valid; version == 1" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    pushManaTable(l, &registry);
    const t: i32 = l.getTop();

    // Exact shape: no more, no less than the three implementable v1 members
    // (ADR 0003 §2 — see this file's module doc for the deferred rest).
    var key_count: usize = 0;
    l.pushNil();
    while (l.next(t)) {
        key_count += 1;
        l.pop(1); // drop value; keep key on the stack to advance `next`
    }
    try testing.expectEqual(@as(usize, 3), key_count);

    try testing.expectEqual(zlua.LuaType.number, l.getField(t, "version"));
    try testing.expectEqual(@as(i64, 1), try l.toInteger(-1));
    l.pop(1);
    try testing.expectEqual(zlua.LuaType.function, l.getField(t, "log"));
    l.pop(1);
    try testing.expectEqual(zlua.LuaType.function, l.getField(t, "is_valid"));
    l.pop(1);
    l.pop(1); // pop table
}

test "mana.is_valid: true for a live handle, false after despawn, and for a forged index" {
    var l = try Lua.init(testing.allocator);
    defer l.deinit();
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.setGeneration(testing.allocator, 3, 1);

    pushManaTable(l, &registry);
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

    pushManaTable(l, &registry);
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

    pushManaTable(l, &registry);
    l.setGlobal("mana");

    try l.doString("mana.log('info')");
}
