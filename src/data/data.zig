//! data — the file layer: the comptime ZON serializer/parser (`zon`), and later
//! file watching + hot reload. Imports `core` only. The serializer's round-trip
//! guarantee is the backbone of the files-as-source-of-truth architecture.

const std = @import("std");
const core = @import("core");

pub const zon = @import("zon.zig");

// Ergonomic re-exports.
pub const serialize = zon.serialize;
pub const parse = zon.parse;
pub const parseLenient = zon.parseLenient;
pub const free = zon.free;

/// Marker that the module is wired into the build graph.
pub const ready = core.ready;

test {
    std.testing.refAllDecls(@This());
    _ = zon;
}
