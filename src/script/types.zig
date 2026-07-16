//! Plain-data leaf types the scripting port hands the engine, independent of which
//! backend is compiled in. They live in their own file (rather than in `script.zig` or
//! `lua.zig`) so BOTH can name them without an import cycle: `script.zig`
//! comptime-selects `lua.zig`, so `lua.zig` must not import `script.zig` back, yet the
//! no-Lua stub build still has to name the types the engine's inert `NoopRuntime`
//! mirrors. Mirrors the `action_types.zig` split `engine` uses for the same reason.
//!
//! Nothing here is a Lua type — that invariant ("nothing above `script` sees a Lua
//! type") is exactly what this file exists to keep.

/// One `<key> = "<value>"` entry read off a table-valued handler field by
/// `lua.State.handlerFieldStrMap` — the string→string channel the engine-side
/// persistence driver reads proposed data through (ADR 0041 §4, the #135
/// handler-table pattern generalised from a scalar to a table).
///
/// Both strings are owned by whoever allocated the pair (the accessor's caller-passed
/// allocator), never by Lua: they are copies, so they stay valid after the Lua value
/// they were read from is collected.
pub const StrPair = struct {
    key: []const u8,
    value: []const u8,
};
