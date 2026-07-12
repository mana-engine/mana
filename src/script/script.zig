//! script — Lua 5.4 integration via ziglua. Scripts decide *what* happens; the
//! engine executes *how*. Imports `core` only. ADR 0003 fixes the `mana` API
//! table's shape; `lua.zig`'s sandboxed `State` installs the subset of it that
//! needs no live Sim/World (`version`, `log`, `is_valid` + opaque entity-handle
//! packing — see `mana.zig`/`handle.zig`) into every script's `_ENV`. The rest
//! of the v1 surface, and engine → script event dispatch, are a later task.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");

/// Placeholder marker verifying the module is wired into the build graph.
pub const ready = core.ready;

/// True when the Lua 5.4 backend was compiled in (`-Denable-lua`).
pub const lua_enabled = build_options.enable_lua;

/// The scripting API version this build provides (ADR 0003 §5 gate): the `mana`
/// version when Lua is compiled in, else 0 (no scripting). The runner compares a
/// package's required `script_api` against this and refuses a package needing more.
pub const api_version: u32 = if (build_options.enable_lua) lua.mana_version else 0;

/// The Lua 5.4 backend (ziglua/zlua) — present only under `-Denable-lua`. Kept
/// behind the comptime flag so the `zlua` import and vendored Lua sources never
/// enter a default build, mirroring how `gpu.zig` guards the Vulkan backend.
pub const lua = if (build_options.enable_lua) @import("lua.zig") else struct {};

test "script module compiles as a stub" {
    try std.testing.expect(ready);
}
