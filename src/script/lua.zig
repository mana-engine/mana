//! Lua 5.4 backend — compiled only under `-Denable-lua`. This is the ONLY module
//! permitted to import the `zlua` (ziglua) bindings; `script.zig` re-exports it
//! behind a comptime flag so the `zlua` import (and vendored Lua sources) never
//! enter a default build. Also implements ADR 0003 §7/§8: one sandboxed
//! `lua_State` per Sim (`State`), with each script module loaded into its own
//! allowlisted `_ENV` (`State.pushSandboxEnv` / `State.loadSandboxed`). The full
//! scripting API (ADR 0003 — the `mana` table, events, opaque handles) is a
//! separate task and is NOT implemented here.

const std = @import("std");
const zlua = @import("zlua");
const mana = @import("mana.zig");

/// The Lua binding type, re-exported so callers need not import `zlua` directly.
pub const Lua = zlua.Lua;

test {
    // `script.zig`'s `if (build_options.enable_lua) @import("lua.zig")` does not
    // pull a comptime-conditionally-imported file's tests into the test binary
    // (see `src/script/CLAUDE.md`); the dedicated `lua_mod` test target in
    // `build.zig` roots directly at this file instead. Referencing `mana`
    // (which in turn imports `handle`) here pulls both files' tests into that
    // same binary the same way — otherwise they would silently never run.
    _ = mana;
}

/// Create a fresh, unsandboxed Lua 5.4 interpreter state with no standard
/// libraries loaded. Caller owns it and must `deinit()`. `gpa` backs Lua's
/// allocations; it must outlive the returned state. Kept for the dependency-spike
/// test below; script content should go through `State.init` instead, which
/// additionally sandboxes the environment (ADR 0003 §7).
pub fn init(gpa: std.mem.Allocator) !*Lua {
    return Lua.init(gpa);
}

test "lua 5.4: evaluating `return 1 + 1` yields 2" {
    var lua = try init(std.testing.allocator);
    defer lua.deinit();

    try lua.doString("return 1 + 1");
    const result = try lua.toInteger(-1);
    try std.testing.expectEqual(@as(i64, 2), result);
}

// --- Sandboxing (ADR 0003 §7, §8) -------------------------------------------

/// Base-library function names exposed *by reference* inside a sandboxed script
/// `_ENV` (ADR 0003 §7). Deliberately excludes `load`/`loadfile`/`dofile`
/// (arbitrary code loading), `collectgarbage`, raw `print` (see `sandboxPrint`),
/// and `_G`/`_VERSION` (either would hand back the real, unsandboxed global
/// table). `getmetatable` is *not* here: it is installed as a wrapper
/// (`sandboxGetmetatable`) that denies the shared string metatable, so it must
/// not also be copied verbatim.
const sandbox_base_fns = [_][:0]const u8{
    "pairs",  "ipairs",   "next",     "select",
    "type",   "tostring", "tonumber", "assert",
    "error",  "pcall",    "xpcall",   "setmetatable",
    "rawget", "rawset",   "rawequal", "rawlen",
};

/// Whole library tables exposed in a sandboxed `_ENV` (as a per-`_ENV` copy, see
/// `pushSandboxEnv`): deterministic, no OS/IO surface (ADR 0003 §7). `math` is
/// handled separately below since its RNG entry points must be stripped first.
const sandbox_whole_libs = [_][:0]const u8{ "string", "table", "coroutine", "utf8" };

/// `math` fields removed for determinism (ADR 0003 §7): nondeterministic global
/// RNG state. `mana.random`/`mana.random_int` (issue #5) draw from the sim's
/// seeded `core.Rng` instead.
const sandbox_math_excluded = [_][:0]const u8{ "random", "randomseed" };

/// One sandboxed Lua 5.4 interpreter — exactly one per `Sim`/world (ADR 0003
/// §8; wiring a `State` into `Sim` itself is a follow-up once `engine` depends
/// on `script`). The underlying `lua_State` never has `os`/`io`/`debug`/
/// `package` loaded at all — not merely hidden from scripts — so nothing run
/// in it can reach the filesystem, network, wall clock, or process, regardless
/// of which allowlisted functions a script has access to. Two `State`s (i.e.
/// two Sims) are two independent `lua_State`s and share no table, including
/// their real `_G` (see the isolation tests below).
pub const State = struct {
    lua: *Lua,
    /// This State's own live-entity generation table, backing the `mana`
    /// table's `is_valid` (ADR 0003 §2, §4; see `mana.zig`). Starts empty; a
    /// later engine → script wiring task will keep it in sync with real
    /// spawns/despawns. Address must stay stable for as long as any script
    /// `_ENV` built from this `State` exists — `pushManaTable` captures a
    /// pointer to it.
    entities: mana.Registry = .{},

    /// Create a fresh sandboxed state. `gpa` backs Lua's own allocations and
    /// must outlive the returned `State`; caller owns it and must `deinit()`.
    /// Opens exactly the libraries ADR 0003 §7 allows scripts to see —
    /// `os`/`io`/`debug`/`package` are never opened, so `require` does not
    /// exist either.
    pub fn init(gpa: std.mem.Allocator) !State {
        const l = try Lua.init(gpa);
        l.openBase();
        l.openString();
        l.openTable();
        l.openCoroutine();
        l.openUtf8();
        l.openMath();

        // Strip math's nondeterministic entry points once, on the one real
        // `math` table this state has. Never exposed to scripts directly
        // either way (only a per-`_ENV` copy is, built below). Proof: `math`
        // was just opened by `openMath` above and nothing has touched the
        // global since, so it is still the library table.
        std.debug.assert(l.getGlobal("math") == .table);
        for (sandbox_math_excluded) |name| {
            l.pushNil();
            l.setField(-2, name);
        }
        l.pop(1);

        return .{ .lua = l };
    }

    /// Destroy the interpreter. Invalidates every value ever pushed from it.
    pub fn deinit(self: *State) void {
        self.entities.deinit(self.lua.allocator());
        self.lua.deinit();
        self.* = undefined;
    }

    /// Push a fresh sandboxed environment table (ADR 0003 §7) onto the Lua
    /// stack: an explicit allowlist of base functions, safe libraries, `math`
    /// minus its RNG, `print` rerouted to the engine log (never raw stdout),
    /// and the `mana` API table (ADR 0003 §2; `mana.zig`). Every script module
    /// gets its own `_ENV` from this call, and its
    /// own **per-`_ENV` shallow copy** of each library table (§8 isolation).
    /// (`mana` is rebuilt fresh for every `_ENV`, same as the library copies,
    /// but there is no isolation concern to guard here either way: it exposes
    /// no mutable engine-owned table a script could reach and corrupt, only
    /// functions and an integer, and every rebuild's closures read the same
    /// `entities` registry on this `State`.)
    /// The copy is what stops one script from corrupting a stdlib function for
    /// its siblings sharing this one `lua_State`: because `rawset` is itself an
    /// allowlisted base function, a single shared (even read-only-proxied)
    /// library table could be rewritten via `rawset(string, "upper", …)` and
    /// poison every sibling — a distinct table per `_ENV` closes that hole
    /// outright. A shallow copy suffices: the entries are immutable C functions
    /// (and, in `math`, immutable number constants), so the copies share the
    /// function objects but not the table any script can mutate. Base functions
    /// and `print` are copied by reference on purpose — they are values, not
    /// mutable containers, and each `_ENV` is itself private, so reassigning
    /// e.g. `pairs` inside one script never touches another.
    pub fn pushSandboxEnv(self: *State) void {
        const l = self.lua;
        l.newTable();

        for (sandbox_base_fns) |name| {
            // Proof: opened by `openBase` in `init`; the base allowlist names
            // only functions `openBase` installs, so each global is a function.
            std.debug.assert(l.getGlobal(name) == .function);
            l.setField(-2, name);
        }
        for (sandbox_whole_libs) |name| {
            self.pushLibCopy(name); // fresh shallow copy per `_ENV`
            l.setField(-2, name);
        }
        self.pushLibCopy("math"); // already RNG-stripped in `init`
        l.setField(-2, "math");

        l.pushFunction(zlua.wrap(sandboxPrint));
        l.setField(-2, "print");

        // `getmetatable` wrapped to deny the shared string metatable (§8; see
        // `sandboxGetmetatable`). The real `getmetatable` is captured as the
        // closure's sole upvalue so tables/userdata keep full behaviour.
        // Proof: `getmetatable` is a base function `openBase` installed in `init`.
        std.debug.assert(l.getGlobal("getmetatable") == .function);
        l.pushClosure(zlua.wrap(sandboxGetmetatable), 1); // consumes the upvalue
        l.setField(-2, "getmetatable");

        mana.pushManaTable(l, &self.entities);
        l.setField(-2, "mana");
    }

    /// Push a fresh shallow copy of the library table currently bound to global
    /// `name`. The new table holds the same key→value entries, but is a
    /// distinct table, so mutating it (including via `rawset`) cannot affect the
    /// original or any other copy — the per-`_ENV` isolation `pushSandboxEnv`
    /// relies on. Copy writes go through `setTableRaw` so a hypothetical
    /// metatable on the source could never intercept them.
    fn pushLibCopy(self: *State, name: [:0]const u8) void {
        const l = self.lua;
        l.newTable();
        const dest = l.getTop(); // absolute index; stable as the stack grows
        // Proof: every `name` passed here was opened in `init` and is untouched,
        // so the global is still its library table.
        std.debug.assert(l.getGlobal(name) == .table);
        l.pushNil(); // first key for the traversal
        while (l.next(-2)) {
            // stack top: … src key value. Duplicate both so `setTableRaw`
            // consumes the copies and leaves the real key for the next step.
            l.pushValue(-2);
            l.pushValue(-2);
            l.setTableRaw(dest);
            l.pop(1); // drop value; keep key to advance `next`
        }
        // `next` returned false having popped the final key; only src remains.
        l.pop(1); // drop src, leaving the fresh copy (`dest`) on top
    }

    /// Load `source` as a script module and rebind its `_ENV` upvalue to a
    /// fresh sandbox (`pushSandboxEnv`) before it ever runs, so it can see only
    /// the allowlisted surface — never the interpreter's real globals. Every
    /// Lua 5.4 top-level chunk has `_ENV` as upvalue 1 unconditionally (the
    /// compiler always emits it), so the assert below never fires on a
    /// well-formed chunk. Leaves the sandboxed chunk (a callable function) on
    /// top of the stack; run it with `Lua.protectedCall`.
    pub fn loadSandboxed(self: *State, source: [:0]const u8) !void {
        const l = self.lua;
        try l.loadString(source);
        const chunk_index = l.getTop();
        self.pushSandboxEnv();
        const upvalue_name = try l.setUpvalue(chunk_index, 1);
        // Proof: `loadString` compiled a top-level chunk, whose upvalue 1 is
        // always `_ENV` (the Lua 5.4 compiler emits it unconditionally); see the
        // doc above. `setUpvalue` already errored if index 1 were out of range.
        std.debug.assert(std.mem.eql(u8, upvalue_name, "_ENV"));
    }
};

/// `print` inside the sandbox: never the stdlib's raw stdout write (that would
/// be a side channel around both the sandbox and the sim's determinism). It
/// stringifies its arguments the way the real `print` does (`__tostring`
/// included) and routes the joined line to the engine log. `mana.log(level,
/// msg)` (issue #5) will front the same sink with an explicit level.
fn sandboxPrint(l: *Lua) !i32 {
    const gpa = l.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const n = l.getTop();
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) try buf.appendSlice(gpa, "\t");
        try buf.appendSlice(gpa, l.toStringEx(i));
        l.pop(1); // toStringEx pushes a new string; drop it once copied.
    }
    std.log.scoped(.script).info("{s}", .{buf.items});
    return 0;
}

/// The sandbox's `getmetatable`, installed as a closure whose sole upvalue is
/// the real `getmetatable`. It returns `nil` for any *string* argument, and
/// delegates everything else to the real function.
///
/// Why strings are special (ADR 0003 §8 isolation): `getmetatable("")` yields
/// the single interpreter-wide string metatable, whose `__index` is the master
/// `string` table that backs both method-call dispatch (`("x"):upper()`) and
/// every script's per-`_ENV` copy. Since `rawset` is allowlisted, a script
/// handed that table could `rawset(getmetatable("").__index, "upper", …)` and
/// permanently poison `string.*` for every sibling script on the shared
/// `lua_State`. Denying the reference is the load-bearing invariant; with no
/// script-reachable handle to that table, neither assignment nor `rawset` can
/// reach it, while `("x"):upper()` keeps resolving through the untouched master.
/// `getmetatable` stays fully functional for tables/userdata, so §7 holds.
fn sandboxGetmetatable(l: *Lua) i32 {
    // No argument: mirror a nil result rather than indexing an invalid slot.
    if (l.getTop() == 0) {
        l.pushNil();
        return 1;
    }
    if (l.typeOf(1) == .string) {
        l.pushNil();
        return 1;
    }
    l.pushValue(Lua.upvalueIndex(1)); // the real getmetatable
    l.pushValue(1); // its argument
    l.call(.{ .args = 1, .results = 1 }); // preserves __metatable protection etc.
    return 1;
}

test "sandbox: pushSandboxEnv builds exactly the allowlisted table shape" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    state.pushSandboxEnv();
    const env: i32 = state.lua.getTop();

    inline for (sandbox_base_fns) |name| {
        try std.testing.expectEqual(zlua.LuaType.function, state.lua.getField(env, name));
        state.lua.pop(1);
    }
    inline for (sandbox_whole_libs) |name| {
        try std.testing.expectEqual(zlua.LuaType.table, state.lua.getField(env, name));
        state.lua.pop(1);
    }
    try std.testing.expectEqual(zlua.LuaType.table, state.lua.getField(env, "math"));
    state.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.function, state.lua.getField(env, "print"));
    state.lua.pop(1);
    // `getmetatable` is present as the string-denying wrapper (a function).
    try std.testing.expectEqual(zlua.LuaType.function, state.lua.getField(env, "getmetatable"));
    state.lua.pop(1);
    // `mana` (ADR 0003 §2) is present as a table; its own shape is asserted in
    // `mana.zig`'s tests.
    try std.testing.expectEqual(zlua.LuaType.table, state.lua.getField(env, "mana"));
    state.lua.pop(1);

    // Nothing else leaks in: no `os`/`io`/`debug`/`_G`/raw `load`/`print` aliasing.
    inline for ([_][:0]const u8{ "os", "io", "debug", "require", "load", "_G", "collectgarbage" }) |name| {
        try std.testing.expectEqual(zlua.LuaType.nil, state.lua.getField(env, name));
        state.lua.pop(1);
    }
    state.lua.pop(1); // pop env
}

test "sandbox: print stringifies its arguments and never raises" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadSandboxed("print('hello', 42, true)");
    try state.lua.protectedCall(.{ .results = 0 });
}

test "sandbox: os, io, debug, require, and _G are absent from a script's _ENV" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    inline for ([_][:0]const u8{
        "os",             "io", "debug",    "require", "load", "loadfile", "dofile",
        "collectgarbage", "_G", "_VERSION",
    }) |global| {
        try state.loadSandboxed("return " ++ global);
        try state.lua.protectedCall(.{ .results = 1 });
        try std.testing.expectEqual(zlua.LuaType.nil, state.lua.typeOf(-1));
        state.lua.pop(1);
    }
}

test "sandbox: os/io are never loaded, not merely hidden — indexing them errors" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadSandboxed("return os.time()");
    try std.testing.expectError(error.LuaRuntime, state.lua.protectedCall(.{ .results = 1 }));
    state.lua.pop(1); // protectedCall leaves the error object on the stack

    try state.loadSandboxed("return io.write('x')");
    try std.testing.expectError(error.LuaRuntime, state.lua.protectedCall(.{ .results = 1 }));
    state.lua.pop(1);
}

test "sandbox: math.random and math.randomseed are removed for determinism" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadSandboxed("return math.random, math.randomseed, math.floor(3.7)");
    try state.lua.protectedCall(.{ .results = 3 });
    try std.testing.expectEqual(zlua.LuaType.number, state.lua.typeOf(-1));
    try std.testing.expectEqual(@as(i64, 3), try state.lua.toInteger(-1));
    try std.testing.expectEqual(zlua.LuaType.nil, state.lua.typeOf(-2));
    try std.testing.expectEqual(zlua.LuaType.nil, state.lua.typeOf(-3));
    state.lua.pop(3);
}

test "sandbox: allowlisted base functions and libraries work end-to-end" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadSandboxed(
        \\local t = {}
        \\for i, v in ipairs({10, 20, 30}) do t[i] = v end
        \\return table.concat(t, ","), string.upper("ok"), type(pcall)
    );
    try state.lua.protectedCall(.{ .results = 3 });
    try std.testing.expectEqualStrings("function", try state.lua.toString(-1));
    try std.testing.expectEqualStrings("OK", try state.lua.toString(-2));
    try std.testing.expectEqualStrings("10,20,30", try state.lua.toString(-3));
    state.lua.pop(3);
}

test "sandbox: two Sims (two States) do not share Lua global state" {
    var a = try State.init(std.testing.allocator);
    defer a.deinit();
    var b = try State.init(std.testing.allocator);
    defer b.deinit();

    a.lua.pushInteger(42);
    a.lua.setGlobal("mutated_by_a");
    try std.testing.expectEqual(zlua.LuaType.nil, b.lua.getGlobal("mutated_by_a"));
    b.lua.pop(1);
    try std.testing.expectEqual(zlua.LuaType.number, a.lua.getGlobal("mutated_by_a"));
    a.lua.pop(1);

    // Reverse direction too, ruling out a coincidental one-way share.
    b.lua.pushInteger(7);
    b.lua.setGlobal("mutated_by_b");
    try std.testing.expectEqual(zlua.LuaType.nil, a.lua.getGlobal("mutated_by_b"));
    a.lua.pop(1);
}

test "sandbox: an implicit global set by a script in one Sim is invisible to another Sim's script" {
    var a = try State.init(std.testing.allocator);
    defer a.deinit();
    var b = try State.init(std.testing.allocator);
    defer b.deinit();

    try a.loadSandboxed("leaked = 99");
    try a.lua.protectedCall(.{ .results = 0 });

    try b.loadSandboxed("return leaked");
    try b.lua.protectedCall(.{ .results = 1 });
    try std.testing.expectEqual(zlua.LuaType.nil, b.lua.typeOf(-1));
    b.lua.pop(1);
}

test "sandbox: one script cannot corrupt a stdlib function for a sibling in the same State" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // Script A, in one `_ENV`, poisons `string` two ways: a plain reassignment
    // (which routes through no metamethod) and a `rawset` (which bypasses any
    // read-only metatable). Both must stay confined to A's own copy.
    try state.loadSandboxed(
        \\string.upper = function() return "PWNED" end
        \\rawset(string, "lower", function() return "PWNED2" end)
    );
    try state.lua.protectedCall(.{ .results = 0 });

    // Script B, loaded into a FRESH `_ENV` on the SAME State (same `lua_State`),
    // must still see the real `string.upper`/`string.lower`.
    try state.loadSandboxed("return string.upper('ok'), string.lower('OK')");
    try state.lua.protectedCall(.{ .results = 2 });
    try std.testing.expectEqualStrings("ok", try state.lua.toString(-1));
    try std.testing.expectEqualStrings("OK", try state.lua.toString(-2));
    state.lua.pop(2);
}

test "sandbox: getmetatable on a string returns nil (string metatable denied)" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadSandboxed("return getmetatable(''), getmetatable('abc')");
    try state.lua.protectedCall(.{ .results = 2 });
    try std.testing.expectEqual(zlua.LuaType.nil, state.lua.typeOf(-1));
    try std.testing.expectEqual(zlua.LuaType.nil, state.lua.typeOf(-2));
    state.lua.pop(2);
}

test "sandbox: getmetatable still works for tables (ADR §7 capability intact)" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // Set a metatable on a fresh table, then confirm getmetatable returns the
    // very same table (identity), proving the delegation path is faithful.
    try state.loadSandboxed(
        \\local mt = {}
        \\local t = setmetatable({}, mt)
        \\return getmetatable(t) == mt
    );
    try state.lua.protectedCall(.{ .results = 1 });
    try std.testing.expect(state.lua.toBoolean(-1));
    state.lua.pop(1);
}

test "sandbox: the string metatable cannot be reached to corrupt a sibling" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // Script A tries to reach the master string table through the string
    // metatable, via both plain assignment and rawset. Both attempts index a
    // nil `getmetatable("")`, so each raises rather than mutating anything.
    try state.loadSandboxed("getmetatable('').__index.upper = function() return 'PWNED' end");
    try std.testing.expectError(error.LuaRuntime, state.lua.protectedCall(.{ .results = 0 }));
    state.lua.pop(1); // error object

    try state.loadSandboxed("rawset(getmetatable('').__index, 'upper', function() return 'PWNED' end)");
    try std.testing.expectError(error.LuaRuntime, state.lua.protectedCall(.{ .results = 0 }));
    state.lua.pop(1);

    // Sibling B on the SAME State still sees the real `string.upper` via BOTH
    // library access and method-call dispatch.
    try state.loadSandboxed("return string.upper('ok'), ('ok'):upper()");
    try state.lua.protectedCall(.{ .results = 2 });
    try std.testing.expectEqualStrings("OK", try state.lua.toString(-1));
    try std.testing.expectEqualStrings("OK", try state.lua.toString(-2));
    state.lua.pop(2);
}
