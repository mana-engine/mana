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

/// Lua-backed runtime (only instantiated under `-Denable-lua`). Owns an optional
/// `script.lua.State`, created lazily on the first `loadHandlers`, so a Sim that
/// never loads a script never spins up an interpreter and dispatch stays a cheap
/// null check.
const LuaRuntime = struct {
    /// Created on demand by `loadHandlers`. Stored by value; its address must be
    /// stable once populated (the sandbox captures a pointer into it), which holds
    /// as long as the owning `Sim` is not moved after loading a script.
    state: ?script.lua.State = null,

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
    /// non-table return, or allocation failure).
    pub fn loadHandlers(self: *LuaRuntime, gpa: Allocator, source: [:0]const u8) !void {
        if (self.state == null) self.state = try script.lua.State.init(gpa);
        try self.state.?.loadHandlerTable(source);
    }

    /// Forward one Sim event to the matching handler-table key (ADR 0003 §3). A
    /// no-op if no script is loaded or the key is absent; a handler error is caught
    /// and logged, never propagated (§9).
    pub fn dispatch(self: *LuaRuntime, ev: event.Event) void {
        const s = if (self.state) |*st| st else return;
        switch (ev) {
            .spawned => |e| report("on_spawn", s, s.dispatchSpawn(e.index, e.generation)),
            .collision_begin => |c| report("on_collision_begin", s, s.dispatchCollisionBegin(
                c.a.index,
                c.a.generation,
                c.b.index,
                c.b.generation,
                0, // the collision event carries no contact normal yet (ADR 0008)
                0,
            )),
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

    /// Log-and-continue (ADR 0003 §9): a caught handler error is reported at `.err`
    /// with the Lua message; `no_handler`/`ok` are silent.
    fn report(name: []const u8, s: *script.lua.State, outcome: script.lua.State.DispatchOutcome) void {
        if (outcome == .errored) {
            std.log.scoped(.script).err("{s} handler errored: {s}", .{ name, s.lastError() });
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
