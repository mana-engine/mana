//! script — Lua 5.4 integration via ziglua. Scripts decide *what* happens; the
//! engine executes *how*. Deferred stub: no scripting API table exists yet, and
//! none may be added until the mandatory ADR defining its shape (event list,
//! opaque handle semantics, versioning) is written. Imports `core` only.

const std = @import("std");
const core = @import("core");

/// Placeholder marker verifying the module is wired into the build graph.
/// The scripting API table is intentionally absent pending its ADR.
pub const ready = core.ready;

test "script module compiles as a stub" {
    try std.testing.expect(ready);
}
