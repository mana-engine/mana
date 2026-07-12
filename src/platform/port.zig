//! The engine-owned platform port vocabulary (ADR 0009): plain-data window/input
//! types with no OS (or adapter) types — `Key`, `InputSnapshot`, `WindowConfig`.
//! Every adapter (headless, SDL3) implements the same `Window` surface over these;
//! nothing here or above `platform` sees an OS handle. The opaque native surface
//! handle a `Window` yields for the `gpu` port is a bare `?*anyopaque` returned at
//! the adapter boundary — never an OS or Vulkan type — so the two ports stay
//! decoupled and Vulkan never leaks upward (CLAUDE.md invariant #4).

const std = @import("std");

/// Engine-owned keyboard keys sampled in an `InputSnapshot`. Deliberately small — the
/// keys a top-down mover needs; extended by a follow-on when a game needs more (ADR
/// 0009: no gamepad in v1). Adapters map OS scancodes to these; nothing above
/// `platform` sees an OS key code.
pub const Key = enum {
    up,
    down,
    left,
    right,
    w,
    a,
    s,
    d,
    space,
    enter,
    escape,
};

/// A set of currently-pressed `Key`s — a plain bitset, sampled once per tick.
pub const KeySet = std.enums.EnumSet(Key);

/// Currently-pressed mouse buttons. Plain data.
pub const MouseButtons = packed struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

/// One frame's worth of input, sampled once per tick by `Window.poll` (ADR 0009:
/// polled, not callback-based; immutable for the tick, so every system reads one
/// value). Plain data, excluded from the sim state hash (like render pacing) — but
/// *given the same snapshot stream a run is bit-identical*, which is what makes the
/// headless scripted-input replay path deterministic.
pub const InputSnapshot = struct {
    /// Keys held this frame.
    keys: KeySet = KeySet.initEmpty(),
    /// Cursor position in window pixels (origin top-left).
    mouse: [2]f32 = .{ 0, 0 },
    /// Mouse buttons held this frame.
    mouse_buttons: MouseButtons = .{},
    /// Vertical scroll-wheel delta accumulated this frame.
    wheel: f32 = 0,
};

/// How a `Window` is opened. Plain data; `title` is borrowed by `open` (must outlive
/// the call; an adapter copies it if it retains it beyond the call).
pub const WindowConfig = struct {
    title: []const u8 = "mana",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
};
