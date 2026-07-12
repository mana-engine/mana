//! Lua 5.4 backend — compiled only under `-Denable-lua`. This is the ONLY module
//! permitted to import the `zlua` (ziglua) bindings; `script.zig` re-exports it
//! behind a comptime flag so the `zlua` import (and vendored Lua sources) never
//! enter a default build. This is the dependency-spike surface only: it proves a
//! Lua 5.4 state can be created and a chunk evaluated. The real scripting API
//! (ADR 0003 — the `mana` table, events, opaque handles) is NOT implemented here.

const std = @import("std");
const zlua = @import("zlua");

/// The Lua binding type, re-exported so callers need not import `zlua` directly.
pub const Lua = zlua.Lua;

/// Create a fresh Lua 5.4 interpreter state. Caller owns it and must `deinit()`.
/// `gpa` backs Lua's allocations; it must outlive the returned state.
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
