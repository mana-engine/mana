//! script — Lua 5.4 integration via ziglua. Scripts decide *what* happens; the
//! engine executes *how*. Deferred stub: no scripting API table exists yet, and
//! none may be added until the mandatory ADR defining its shape (event list,
//! opaque handle semantics, versioning) is written. Imports `core` only.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");

/// Placeholder marker verifying the module is wired into the build graph.
/// The scripting API table is intentionally absent pending its ADR.
pub const ready = core.ready;

/// True when the Lua 5.4 backend was compiled in (`-Denable-lua`).
pub const lua_enabled = build_options.enable_lua;

/// The Lua 5.4 backend (ziglua/zlua) — present only under `-Denable-lua`. Kept
/// behind the comptime flag so the `zlua` import and vendored Lua sources never
/// enter a default build, mirroring how `gpu.zig` guards the Vulkan backend. This
/// is the dependency-spike surface only; the scripting API (ADR 0003) is not yet
/// implemented and must not be added until its implementation task.
pub const lua = if (build_options.enable_lua) @import("lua.zig") else struct {};

test "script module compiles as a stub" {
    try std.testing.expect(ready);
}
