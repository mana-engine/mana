//! The engine-owned platform port vocabulary (ADR 0009): plain-data window/input
//! types with no OS (or adapter) types — `Key`, `InputSnapshot`, `WindowConfig`.
//! Every adapter (headless, SDL3) implements the same `Window` surface over these;
//! nothing here or above `platform` sees an OS handle. The opaque native surface
//! handle a `Window` yields for the `gpu` port is a bare `?*anyopaque` returned at
//! the adapter boundary — never an OS or Vulkan type — so the two ports stay
//! decoupled and Vulkan never leaks upward (CLAUDE.md invariant #4).

const std = @import("std");

/// Engine-owned keyboard keys sampled in an `InputSnapshot`. Deliberately small — the
/// keys a top-down mover needs; extended by a follow-on when a game needs more.
/// Adapters map OS scancodes to these; nothing above `platform` sees an OS key code.
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

/// Engine-owned gamepad buttons sampled in an `InputSnapshot` (ADR 0040 §5), named
/// after SDL's standardized gamepad button set. Adapters map OS/SDL button codes to
/// these; nothing above `platform` sees an OS/SDL button code. One gamepad (player 1)
/// only in v1 — no multi-pad routing.
pub const GamepadButton = enum {
    south,
    east,
    west,
    north,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    left_shoulder,
    right_shoulder,
    left_stick,
    right_stick,
    start,
    back,
    guide,
};

/// A set of currently-held `GamepadButton`s — a plain bitset, sampled once per tick,
/// mirroring `KeySet`.
pub const GamepadButtonSet = std.enums.EnumSet(GamepadButton);

/// Engine-owned analog gamepad axes sampled in an `InputSnapshot` (ADR 0040 §5).
/// Sticks (`left_x`/`left_y`/`right_x`/`right_y`) range `[-1, 1]`; triggers
/// (`left_trigger`/`right_trigger`) range `[0, 1]`. First-class analog values — never
/// pre-discretized into digital state.
pub const GamepadAxis = enum {
    left_x,
    left_y,
    right_x,
    right_y,
    left_trigger,
    right_trigger,
};

/// Analog gamepad axis values, one `f32` per `GamepadAxis`, sampled once per tick.
/// A fixed array indexed by the enum (see `GamepadAxis` for per-axis range/units).
pub const GamepadAxes = std.enums.EnumArray(GamepadAxis, f32);

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
    /// Gamepad buttons held this frame (player 1 only, ADR 0040 §5).
    pad_buttons: GamepadButtonSet = GamepadButtonSet.initEmpty(),
    /// Gamepad analog axis values this frame (player 1 only, ADR 0040 §5); zeroed
    /// when no gamepad is connected.
    pad_axes: GamepadAxes = GamepadAxes.initFill(0),
    /// Whether a gamepad is present this frame (ADR 0040 §5: a polled flag, not a
    /// connect/disconnect edge event).
    pad_connected: bool = false,
};

/// How a `Window` is opened. Plain data; `title` is borrowed by `open` (must outlive
/// the call; an adapter copies it if it retains it beyond the call).
pub const WindowConfig = struct {
    title: []const u8 = "mana",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
};

const testing = std.testing;

test "InputSnapshot default: no gamepad connected, no buttons held, axes zeroed" {
    const snap = InputSnapshot{};
    try testing.expect(!snap.pad_connected);
    try testing.expectEqual(@as(usize, 0), snap.pad_buttons.count());
    try testing.expectEqual(@as(f32, 0), snap.pad_axes.get(.left_x));
    try testing.expectEqual(@as(f32, 0), snap.pad_axes.get(.left_trigger));
}
