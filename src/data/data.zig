//! data — the file layer: the comptime ZON serializer/parser (`zon`), and later
//! file watching + hot reload. Imports `core` only. The serializer's round-trip
//! guarantee is the backbone of the files-as-source-of-truth architecture.

const std = @import("std");
const core = @import("core");

pub const zon = @import("zon.zig");
pub const watch = @import("watch.zig");
pub const png = @import("png.zig");
/// The MSF2 sprite-sheet container (ADR 0031, ADR 0033): `encode` (used by `tools/spritegen`)
/// and `decode` (used by the engine's sprite loader) of a dependency-free RGBA8
/// frame + clip container. The single definition of the format on both sides.
pub const msf = @import("msf.zig");

// Ergonomic re-exports.
pub const serialize = zon.serialize;
pub const parse = zon.parse;
pub const parseLenient = zon.parseLenient;
pub const free = zon.free;
pub const Watcher = watch.Watcher;

/// Marker that the module is wired into the build graph.
pub const ready = core.ready;

test {
    std.testing.refAllDecls(@This());
    _ = zon;
    _ = watch;
    _ = png;
    _ = msf;
}
