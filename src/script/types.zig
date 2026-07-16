//! Plain-data leaf types the scripting port hands the engine, independent of which
//! backend is compiled in. They live in their own file, rather than in `lua.zig`, because
//! **`lua.zig` does not exist in a default build**: `script.zig` resolves `pub const lua`
//! to an empty `struct {}` without `-Denable-lua`, so a type declared there would be
//! unnameable exactly when the engine's inert `NoopRuntime` needs to mirror the accessor
//! signatures that use it. A leaf file both the stub and the backend import is the way
//! out — the same split `engine` uses for `action_types.zig`.
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
