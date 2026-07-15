//! Lua 5.4 backend — compiled only under `-Denable-lua`. This is the ONLY module
//! permitted to import the `zlua` (ziglua) bindings; `script.zig` re-exports it
//! behind a comptime flag so the `zlua` import (and vendored Lua sources) never
//! enter a default build. Also implements ADR 0003 §7/§8: one sandboxed
//! `lua_State` per Sim (`State`), with each script module loaded into its own
//! allowlisted `_ENV` (`State.pushSandboxEnv` / `State.loadSandboxed`), plus ADR
//! 0003 §1/§3/§9 event dispatch: `State` loads one handler table and forwards Sim
//! events (`on_spawn`, `on_collision_begin`) to it, catching handler errors.
//!
//! Over the ~500-line soft limit by design: the sandbox, the `mana` install, and
//! event dispatch all bind to the one per-Sim `State` and its single `lua_State`,
//! so they stay one cohesive compilation unit rather than fragmenting `State`'s
//! methods across files (a method must live in its struct's body).

const std = @import("std");
const zlua = @import("zlua");
const mana = @import("mana.zig");

/// The Lua binding type, re-exported so callers need not import `zlua` directly.
pub const Lua = zlua.Lua;

/// The host seam type (ADR 0015), re-exported so the engine can build a `Host`
/// (`script.lua.Host`) and hand it to `State.setHost` without importing `host.zig`.
pub const Host = mana.Host;

/// The `mana` API version this backend implements (ADR 0003 §5), re-exported as a
/// `u32` so the runner can advertise the provided scripting API without reaching
/// into `mana.zig`.
pub const mana_version: u32 = @intCast(mana.version);

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
    /// This State's own live-entity generation table, the `is_valid` fallback used
    /// when no `Host` is installed (ADR 0003 §2, §4; see `mana.zig`). Address must
    /// stay stable for as long as any script `_ENV` built from this `State` exists —
    /// `pushManaTable` captures a pointer to it.
    entities: mana.Registry = .{},

    /// The live-Sim host seam (ADR 0015), or null when no Sim is dispatching. The
    /// engine sets this via `setHost` immediately before invoking a handler and
    /// clears it after, so the `mana` accessors (`position`, `now`, and the
    /// authoritative `is_valid`) reach the live world only during a dispatch.
    /// `pushManaTable` captures a pointer to this slot; its address must stay stable
    /// for the `State`'s lifetime (same requirement as `entities`).
    host: ?mana.Host = null,

    /// Registry reference (`luaL_ref`) to this Sim's single loaded handler table
    /// (ADR 0003 §1), or null before `loadHandlerTable` runs. One table per
    /// `State`; `loadHandlerTable` replaces it (hot reload, §8). Freed in `deinit`.
    handler_ref: ?i32 = null,

    /// Scratch for the most recent caught handler error message (ADR 0003 §9).
    /// `dispatch*` copies the Lua error string here before unwinding the stack so
    /// the engine can log it *after* dispatch returns; valid until the next
    /// dispatch. Truncated to fit; content is diagnostic only (never hashed).
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

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
        if (self.handler_ref) |r| self.lua.unref(zlua.registry_index, r);
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

        mana.pushManaTable(l, &self.entities, &self.host);
        l.setField(-2, "mana");
    }

    /// Install (or clear, with `null`) the live-Sim host seam (ADR 0015) the `mana`
    /// accessors call through. The engine sets a live `Host` around each event
    /// dispatch and clears it after, so a `mana` read reaches the world only while a
    /// handler is running. Cheap: a single optional assignment.
    pub fn setHost(self: *State, h: ?mana.Host) void {
        self.host = h;
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

    // --- Event dispatch (ADR 0003 §1, §3, §9) -------------------------------

    /// The result of dispatching one event to the handler table. Returned rather
    /// than logged so the fragile stack-balancing on the error path is unit
    /// testable without emitting an `.err` log (which the Zig test runner counts
    /// as a failure); the engine logs `.errored` itself, reading `lastError`.
    pub const DispatchOutcome = enum {
        /// The handler key was absent (a plain no-op, the common cheap case).
        no_handler,
        /// The handler ran to completion.
        ok,
        /// The handler raised; its effects are unwound and `lastError` is set.
        errored,
    };

    /// Load `source` as this Sim's single handler table (ADR 0003 §1): run the
    /// sandboxed module and cache the table it returns in the Lua registry for
    /// event dispatch. Replaces any previously loaded table (hot reload, §8;
    /// timers of the old table are the follow-up task's concern). `source` is a
    /// NUL-terminated Lua chunk, borrowed only for the call. Errors:
    /// `error.LuaRuntime`/`error.LuaSyntax` if the module fails to load or run,
    /// `error.NotAHandlerTable` if it does not return a table, `error.OutOfMemory`.
    pub fn loadHandlerTable(self: *State, source: [:0]const u8) !void {
        const l = self.lua;
        try self.loadSandboxed(source); // leaves the sandboxed chunk on the stack
        try l.protectedCall(.{ .results = 1 }); // run it → its return value on top
        if (l.typeOf(-1) != .table) {
            l.pop(1);
            return error.NotAHandlerTable;
        }
        // Swap atomically: only release the previous ref once the new table is in
        // hand, so a failed load above leaves the old handlers intact.
        if (self.handler_ref) |r| self.lua.unref(zlua.registry_index, r);
        self.handler_ref = l.ref(zlua.registry_index); // pops the table, stores it
    }

    /// Dispatch `on_spawn(self)` (ADR 0003 §3) — `self` is the spawned entity as
    /// an opaque handle (§4). A missing key is a silent no-op. `index`/`generation`
    /// are the raw entity fields the engine passes; the handle packing stays inside
    /// `script` so no Lua/handle type leaks upward. Never raises: a handler error
    /// is caught and reported via the return value (§9).
    pub fn dispatchSpawn(self: *State, index: u32, generation: u32) DispatchOutcome {
        if (!self.pushHandler("on_spawn")) return .no_handler;
        self.pushHandle(index, generation);
        return self.invokeHandler(1);
    }

    /// Dispatch the per-scene bootstrap `on_scene_enter(ev)` (ADR 0017) where
    /// `ev = { scene = <name> }`. Unlike the entity events there is no `self` — the
    /// handler is scene-level, not entity-level. A missing key is a silent no-op; a
    /// handler error is caught and reported (§9). `scene_name` is borrowed only for
    /// the call (copied into the Lua string).
    pub fn dispatchSceneEnter(self: *State, scene_name: []const u8) DispatchOutcome {
        if (!self.pushHandler("on_scene_enter")) return .no_handler;
        const l = self.lua;
        l.newTable(); // arg 1: ev (no self — scene-level handler)
        _ = l.pushString(scene_name);
        l.setField(-2, "scene");
        return self.invokeHandler(1);
    }

    /// Dispatch `on_collision_begin(self, ev)` (ADR 0003 §3) where `ev = { other,
    /// normal_x, normal_y }`. `self`/`other` are opaque handles (§4); the engine's
    /// `collision_begin` event carries no contact normal yet, so callers pass `0`
    /// for both components until the collision system computes one. A missing key
    /// is a no-op; a handler error is caught and reported (§9).
    pub fn dispatchCollisionBegin(
        self: *State,
        self_index: u32,
        self_generation: u32,
        other_index: u32,
        other_generation: u32,
        normal_x: f32,
        normal_y: f32,
    ) DispatchOutcome {
        if (!self.pushHandler("on_collision_begin")) return .no_handler;
        const l = self.lua;
        self.pushHandle(self_index, self_generation); // arg 1: self
        l.newTable(); // arg 2: ev
        self.pushHandle(other_index, other_generation);
        l.setField(-2, "other");
        l.pushNumber(normal_x);
        l.setField(-2, "normal_x");
        l.pushNumber(normal_y);
        l.setField(-2, "normal_y");
        return self.invokeHandler(2);
    }

    /// Dispatch a keyboard edge `on_key(ev)` (ADR 0021) where `ev = { key, pressed }`.
    /// `key` is the neutral key-name string (no `platform` type crosses down); no
    /// `self` (input is global, like `on_scene_enter`). A missing key is a no-op; a
    /// handler error is caught and reported (§9). `key_name` is borrowed for the call.
    pub fn dispatchKey(self: *State, key_name: []const u8, pressed: bool) DispatchOutcome {
        if (!self.pushHandler("on_key")) return .no_handler;
        const l = self.lua;
        l.newTable(); // arg 1: ev (no self — global input)
        _ = l.pushString(key_name);
        l.setField(-2, "key");
        l.pushBoolean(pressed);
        l.setField(-2, "pressed");
        return self.invokeHandler(1);
    }

    /// Dispatch an action edge `on_action(ev)` (ADR 0040 §2) where `ev = { action,
    /// pressed }`. `action` is the content-declared action name string — device-agnostic
    /// (no `platform` type crosses down), mirroring `on_key`'s `pressed`-flagged edge
    /// shape. `pressed` is `true` on the combined-held down edge, `false` on the up edge.
    /// No `self` (input is global, like `on_key`/`on_scene_enter`). A missing handler is a
    /// no-op; a handler error is caught and reported (§9). `action_name` is borrowed for
    /// the call.
    pub fn dispatchAction(self: *State, action_name: []const u8, pressed: bool) DispatchOutcome {
        if (!self.pushHandler("on_action")) return .no_handler;
        const l = self.lua;
        l.newTable(); // arg 1: ev (no self — global input)
        _ = l.pushString(action_name);
        l.setField(-2, "action");
        l.pushBoolean(pressed);
        l.setField(-2, "pressed");
        return self.invokeHandler(1);
    }

    /// Dispatch a UI pointer click `on_click(ev = { widget, id, x, y })` (ADR 0039 §1)
    /// where `widget` is the opaque widget handle (§2), `id` the hit widget's authored
    /// name (`""` when anonymous), and `x`/`y` the press point in screen pixels. No
    /// `self` — UI screens are not entities, like `on_key`/`on_scene_enter`. A missing
    /// key is a no-op; a handler error is caught and reported (§9). `id` is borrowed for
    /// the call. The `index`/`generation` are the engine-assigned widget-table fields;
    /// the handle packing stays inside `script`, so no Lua/handle type leaks upward.
    pub fn dispatchClick(self: *State, index: u32, generation: u32, id: []const u8, x: f32, y: f32) DispatchOutcome {
        if (!self.pushHandler("on_click")) return .no_handler;
        const l = self.lua;
        l.newTable(); // arg 1: ev (no self — UI is global, not entity-level)
        self.pushWidgetHandle(index, generation);
        l.setField(-2, "widget");
        _ = l.pushString(id);
        l.setField(-2, "id");
        l.pushNumber(x);
        l.setField(-2, "x");
        l.pushNumber(y);
        l.setField(-2, "y");
        return self.invokeHandler(1);
    }

    /// Dispatch a UI focus entry `on_focus(ev = { widget, id })` (ADR 0039 §1) — fired
    /// when keyboard/gamepad/pointer navigation moves focus *onto* a new widget. No
    /// `x`/`y`: nav-driven focus has no pointer coordinate (§1). Same no-`self`, caught-
    /// error semantics as `dispatchClick`. `id` is borrowed for the call.
    pub fn dispatchFocus(self: *State, index: u32, generation: u32, id: []const u8) DispatchOutcome {
        return self.dispatchWidgetEvent("on_focus", index, generation, id);
    }

    /// Dispatch a UI activation `on_activate(ev = { widget, id })` (ADR 0039 §1) — fired
    /// on the currently focused widget when an activate key's press edge lands. No
    /// `x`/`y`: key-driven activation has no pointer coordinate (§1). Same semantics as
    /// `dispatchFocus`. `id` is borrowed for the call.
    pub fn dispatchActivate(self: *State, index: u32, generation: u32, id: []const u8) DispatchOutcome {
        return self.dispatchWidgetEvent("on_activate", index, generation, id);
    }

    /// Shared body of `dispatchFocus`/`dispatchActivate` (ADR 0039 §1): both carry the
    /// identical `ev = { widget, id }` payload and differ only in the handler key.
    fn dispatchWidgetEvent(self: *State, comptime key: [:0]const u8, index: u32, generation: u32, id: []const u8) DispatchOutcome {
        if (!self.pushHandler(key)) return .no_handler;
        const l = self.lua;
        l.newTable(); // arg 1: ev (no self)
        self.pushWidgetHandle(index, generation);
        l.setField(-2, "widget");
        _ = l.pushString(id);
        l.setField(-2, "id");
        return self.invokeHandler(1);
    }

    /// Invoke a Lua timer callback by its registry `ref` (ADR 0019 `mana.after`/
    /// `every`). Pushes the referenced function and calls it in protected mode with
    /// no arguments; a throwing callback is caught and reported via the return value
    /// (§9), never raised. The engine installs the host around timer advance, so the
    /// callback's `mana` calls resolve. `ref` must be a live reference (the engine
    /// releases it exactly once, on fire/cancel/teardown — never double-invokes).
    pub fn invokeTimerRef(self: *State, ref: i32) DispatchOutcome {
        const l = self.lua;
        _ = l.getIndexRaw(zlua.registry_index, ref); // push the referenced function
        l.protectedCall(.{ .args = 0, .results = 0 }) catch {
            self.captureError();
            l.pop(1); // the error object
            return .errored;
        };
        return .ok;
    }

    /// Release a Lua timer callback reference (ADR 0019) — called by the engine when
    /// a one-shot fires, a timer is cancelled, or on teardown. `luaL_unref` tolerates
    /// a stale reference, so this is safe to call once per reference.
    pub fn releaseTimerRef(self: *State, ref: i32) void {
        self.lua.unref(zlua.registry_index, ref);
    }

    /// Read integer field `key` off the loaded handler table, or null if no table
    /// is loaded or the field is absent/non-integer. Lets the engine observe
    /// handler-declared scalars (and dispatch effects, in tests) without exposing
    /// a Lua type upward.
    pub fn handlerFieldInt(self: *State, key: [:0]const u8) ?i64 {
        const l = self.lua;
        const ref = self.handler_ref orelse return null;
        _ = l.getIndexRaw(zlua.registry_index, ref); // push the table
        const ty = l.getField(-1, key); // push the field value
        defer l.pop(2); // value + table
        if (ty != .number) return null;
        return l.toInteger(-1) catch null;
    }

    /// The most recent caught handler error message (ADR 0003 §9), valid until the
    /// next dispatch. Empty when the last dispatch did not error.
    pub fn lastError(self: *const State) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// Push the loaded handler table then its `key` field; if that field is a
    /// function, leave `[table, fn]` on the stack and return true (caller pushes
    /// args and calls `invokeHandler`). Otherwise restore the stack and return
    /// false (no table loaded, or the key is absent/not callable → no-op).
    fn pushHandler(self: *State, key: [:0]const u8) bool {
        const l = self.lua;
        const ref = self.handler_ref orelse return false;
        _ = l.getIndexRaw(zlua.registry_index, ref); // push the table
        if (l.getField(-1, key) != .function) {
            l.pop(2); // the non-function value + the table
            return false;
        }
        return true; // stack: [..., table, fn]
    }

    /// Call the handler resolved by `pushHandler`, whose `nargs` arguments are
    /// already pushed above it, in protected mode. Always leaves the stack as it
    /// found it before `pushHandler` (pops the table, the function, its args, and
    /// any error object). On error, copies the message into `err_buf` (§9).
    fn invokeHandler(self: *State, nargs: i32) DispatchOutcome {
        const l = self.lua;
        // stack: [..., table, fn, arg1..argN]; protectedCall pops fn + args.
        l.protectedCall(.{ .args = nargs, .results = 0 }) catch {
            self.captureError(); // reads the error object at the top of the stack
            l.pop(2); // the error object + the table
            return .errored;
        };
        l.pop(1); // the table (protectedCall consumed fn + args, pushed nothing)
        return .ok;
    }

    /// Copy the error object at the top of the stack into `err_buf` (truncating to
    /// fit) so the engine can log it after the stack unwinds. `toStringEx` pushes a
    /// string copy which this pops, leaving the original error object on top.
    fn captureError(self: *State) void {
        const l = self.lua;
        const msg = l.toStringEx(-1); // pushes a string form of the error object
        defer l.pop(1); // drop that copy
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }

    /// Push an opaque entity handle (ADR 0003 §4) as the single Lua integer scripts
    /// receive. The `mana` handle packing lives here so no handle/Lua type leaks
    /// above `script`.
    fn pushHandle(self: *State, index: u32, generation: u32) void {
        const raw = mana.Handle.pack(.{ .index = index, .generation = generation });
        self.lua.pushInteger(@bitCast(raw));
    }

    /// Push an opaque **widget** handle (ADR 0039 §2) as the single Lua integer a UI
    /// event's `ev.widget` field carries. A distinct handle kind from `pushHandle`'s
    /// entity handle (drawn from the widget-handle table), sharing only the bit layout;
    /// the packing stays here so no handle/Lua type leaks above `script`.
    fn pushWidgetHandle(self: *State, index: u32, generation: u32) void {
        const raw = mana.WidgetHandle.pack(.{ .index = index, .generation = generation });
        self.lua.pushInteger(@bitCast(raw));
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

// --- Event dispatch (ADR 0003 §1, §3, §9) -----------------------------------

test "dispatch: on_spawn fires for a loaded handler table" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadHandlerTable(
        \\local t = { spawns = 0 }
        \\function t.on_spawn(self) t.spawns = t.spawns + 1 end
        \\return t
    );

    try std.testing.expectEqual(@as(i64, 0), state.handlerFieldInt("spawns").?);
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchSpawn(1, 0));
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("spawns").?);
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchSpawn(2, 0));
    try std.testing.expectEqual(@as(i64, 2), state.handlerFieldInt("spawns").?);
}

test "dispatch: a missing handler key is a silent no-op" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // A table with no `on_spawn`/`on_collision_begin` at all.
    try state.loadHandlerTable("return { unrelated = 1 }");
    try std.testing.expectEqual(State.DispatchOutcome.no_handler, state.dispatchSpawn(1, 0));
    try std.testing.expectEqual(
        State.DispatchOutcome.no_handler,
        state.dispatchCollisionBegin(1, 0, 2, 0, 0, 0),
    );
}

test "dispatch: with no table loaded every event is a no-op" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(State.DispatchOutcome.no_handler, state.dispatchSpawn(1, 0));
    try std.testing.expect(state.handlerFieldInt("anything") == null);
}

test "dispatch: a throwing handler is caught, reported, and the state stays usable" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // `on_spawn` raises; `on_collision_begin` is well-behaved. Proving the second
    // still runs afterwards proves the error path unwound the stack cleanly.
    try state.loadHandlerTable(
        \\local t = { collisions = 0 }
        \\function t.on_spawn(self) error("boom") end
        \\function t.on_collision_begin(self, ev) t.collisions = t.collisions + 1 end
        \\return t
    );

    try std.testing.expectEqual(State.DispatchOutcome.errored, state.dispatchSpawn(1, 0));
    try std.testing.expect(std.mem.indexOf(u8, state.lastError(), "boom") != null);

    // The stack is balanced, so a subsequent dispatch works normally.
    try std.testing.expectEqual(
        State.DispatchOutcome.ok,
        state.dispatchCollisionBegin(1, 0, 2, 0, 0, 0),
    );
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("collisions").?);
}

test "dispatch: on_collision_begin receives self and an ev table with other/normals" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadHandlerTable(
        \\local t = { hits = 0, other_present = 0, normals_present = 0 }
        \\function t.on_collision_begin(self, ev)
        \\  t.hits = t.hits + 1
        \\  if ev.other ~= nil then t.other_present = 1 end
        \\  if ev.normal_x ~= nil and ev.normal_y ~= nil then t.normals_present = 1 end
        \\end
        \\return t
    );

    try std.testing.expectEqual(
        State.DispatchOutcome.ok,
        state.dispatchCollisionBegin(1, 0, 2, 0, 0.5, -0.5),
    );
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("hits").?);
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("other_present").?);
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("normals_present").?);
}

test "dispatch: loading a non-table module is rejected without clobbering a prior table" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadHandlerTable(
        \\local t = { spawns = 0 }
        \\function t.on_spawn(self) t.spawns = t.spawns + 1 end
        \\return t
    );
    try std.testing.expectError(error.NotAHandlerTable, state.loadHandlerTable("return 42"));

    // The previously loaded table survives the failed reload.
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchSpawn(1, 0));
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("spawns").?);
}

test "dispatch: loadHandlerTable replaces the previous table (hot reload)" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadHandlerTable("return { generation = 1 }");
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("generation").?);
    try state.loadHandlerTable("return { generation = 2 }");
    try std.testing.expectEqual(@as(i64, 2), state.handlerFieldInt("generation").?);
}

// --- UI event dispatch (ADR 0039 §1) ----------------------------------------

test "dispatch: on_click delivers the widget handle, id, and pointer coords" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    // The handler records the packed widget handle, whether the id matched, and the
    // coordinates — everything ADR 0039 §1 says `on_click`'s `ev` carries.
    try state.loadHandlerTable(
        \\local t = { clicks = 0, widget = 0, id_ok = 0, x = 0, y = 0 }
        \\function t.on_click(ev)
        \\  t.clicks = t.clicks + 1
        \\  t.widget = ev.widget
        \\  if ev.id == "start" then t.id_ok = 1 end
        \\  t.x = ev.x
        \\  t.y = ev.y
        \\end
        \\return t
    );

    // Widget at pre-order index 3, generation 1, id "start", clicked at (12, 34).
    const expect: i64 = @bitCast(mana.WidgetHandle.pack(.{ .index = 3, .generation = 1 }));
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchClick(3, 1, "start", 12, 34));
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("clicks").?);
    try std.testing.expectEqual(expect, state.handlerFieldInt("widget").?);
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("id_ok").?);
    try std.testing.expectEqual(@as(i64, 12), state.handlerFieldInt("x").?);
    try std.testing.expectEqual(@as(i64, 34), state.handlerFieldInt("y").?);
}

test "dispatch: on_focus and on_activate carry widget + id, no coordinates" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    try state.loadHandlerTable(
        \\local t = { focus = 0, activate = 0, f_widget = 0, a_id_ok = 0, saw_xy = 0 }
        \\function t.on_focus(ev)
        \\  t.focus = t.focus + 1
        \\  t.f_widget = ev.widget
        \\  if ev.x ~= nil or ev.y ~= nil then t.saw_xy = 1 end
        \\end
        \\function t.on_activate(ev)
        \\  t.activate = t.activate + 1
        \\  if ev.id == "ok_button" then t.a_id_ok = 1 end
        \\end
        \\return t
    );

    const w: i64 = @bitCast(mana.WidgetHandle.pack(.{ .index = 2, .generation = 5 }));
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchFocus(2, 5, "ok_button"));
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchActivate(2, 5, "ok_button"));
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("focus").?);
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("activate").?);
    try std.testing.expectEqual(w, state.handlerFieldInt("f_widget").?);
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("a_id_ok").?);
    // on_focus/on_activate carry no x/y (ADR 0039 §1).
    try std.testing.expectEqual(@as(i64, 0), state.handlerFieldInt("saw_xy").?);
}

test "dispatch: UI events with no matching handler key are silent no-ops" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    try state.loadHandlerTable("return { unrelated = 1 }");
    try std.testing.expectEqual(State.DispatchOutcome.no_handler, state.dispatchClick(0, 0, "", 0, 0));
    try std.testing.expectEqual(State.DispatchOutcome.no_handler, state.dispatchFocus(0, 0, ""));
    try std.testing.expectEqual(State.DispatchOutcome.no_handler, state.dispatchActivate(0, 0, ""));
}

test "dispatch: a throwing on_click is caught and reported, leaving the state usable" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    try state.loadHandlerTable(
        \\local t = { focuses = 0 }
        \\function t.on_click(ev) error("boom") end
        \\function t.on_focus(ev) t.focuses = t.focuses + 1 end
        \\return t
    );
    try std.testing.expectEqual(State.DispatchOutcome.errored, state.dispatchClick(0, 0, "x", 1, 1));
    try std.testing.expect(std.mem.indexOf(u8, state.lastError(), "boom") != null);
    // The stack unwound cleanly: a later dispatch still runs.
    try std.testing.expectEqual(State.DispatchOutcome.ok, state.dispatchFocus(0, 0, "y"));
    try std.testing.expectEqual(@as(i64, 1), state.handlerFieldInt("focuses").?);
}
