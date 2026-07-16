//! Shared leaf types for the data-driven action-binding table (ADR 0040 §3). These are the
//! plain-data structs both the parser (`action_parse.zig`) and the pure resolver
//! (`action_resolve.zig`) build against — factored into their own file so neither sibling
//! needs a back-`@import` of the other (issue #217 follow-up split, mirroring `ui.zig` →
//! `ui/types.zig`; each of the three siblings stays under the ~500-line soft limit). The
//! public API is unchanged — `action_map.zig` re-exports every symbol here, so callers still
//! name `engine.action_map.RawAction`, `engine.ActionMap`, etc.
//!
//! Actions are content-named — nothing in `src/**` hardcodes an action name (invariant #6);
//! the namespace is entirely whatever a game's `input.zon` declares.

const std = @import("std");
const platform = @import("platform");

/// An action's declared value type (ADR 0040 §1): `button` is digital (down/up, read
/// via `on_action`/`action_down`), `axis1d` is a single analog `f32`, `axis2d` an
/// analog `(x, y)` vector. The type dictates which of `RawAction`'s source fields are
/// legal — `validate` (in `action_parse.zig`) enforces that a source never crosses type
/// (analog stays analog).
pub const ActionType = enum { button, axis1d, axis2d };

/// Which physical stick a `pad_stick` binding reads — the whole stick, x and y at
/// once (ADR 0040 §3).
pub const Stick = enum { left, right };

/// The four key-groups an `axis2d` action synthesizes into a vector (ADR 0040 §4):
/// held opposites cancel, the raw vector normalizes to unit length past magnitude 1.
/// Each group is a list because multiple physical keys may drive the same direction
/// (e.g. both arrow keys and WASD). Resolving these into a value is `action_resolve.zig`
/// (issue #217) — this struct only stores the bound key lists.
pub const Keys2d = struct {
    up: []const platform.Key = &.{},
    down: []const platform.Key = &.{},
    left: []const platform.Key = &.{},
    right: []const platform.Key = &.{},
};

/// The `pos`/`neg` key groups an `axis1d` action synthesizes into `{-1, 0, +1}`
/// (ADR 0040 §4), mirroring `Keys2d` for one dimension.
pub const Keys1d = struct {
    pos: []const platform.Key = &.{},
    neg: []const platform.Key = &.{},
};

/// Engine default radial dead-zone (ADR 0040 §4) applied to a native analog source
/// when an action's `input.zon` entry omits `deadzone`.
pub const default_deadzone: f32 = 0.15;

/// One action's raw binding, exactly ADR 0040 §3's ZON shape (§4 amended for
/// `pad_dpad`, #230): a `type` tag plus every possible source field, flat (not a Zig
/// tagged union) because that is the literal on-disk shape the ADR pins. Only the
/// fields matching `type` are meaningful — `validate` rejects a binding that sets a
/// field belonging to a different type (e.g. `pad_stick` on a `button` action) or that
/// binds nothing at all. `keys`/`pad_buttons` are used by `button` actions only;
/// `axis1d`/`axis2d` actions use `keys_1d`/`keys_2d`/`pad_dpad` instead (ADR 0040 §3's
/// rejected-alternatives: a flat key list cannot express which direction each key
/// drives).
pub const RawAction = struct {
    type: ActionType,
    /// `button` only: any listed key held ⇒ the action is held (edges OR-combined).
    keys: []const platform.Key = &.{},
    /// `button` only: any listed gamepad button held ⇒ the action is held.
    pad_buttons: []const platform.GamepadButton = &.{},
    /// `axis2d` only: the native stick this action reads, if any.
    pad_stick: ?Stick = null,
    /// `axis1d` only: the native trigger/axis this action reads, if any.
    pad_axis: ?platform.GamepadAxis = null,
    /// `axis2d` only: the synthesized-from-keys vector source, if any.
    keys_2d: ?Keys2d = null,
    /// `axis1d` only: the synthesized-from-keys value source, if any.
    keys_1d: ?Keys1d = null,
    /// `axis2d` only (ADR 0040 §4 amendment, #230): when `true`, synthesize a vector
    /// from the four canonical d-pad buttons (`platform.GamepadButton.dpad_up/down/
    /// left/right`), same sign convention as `keys_2d` (right +x, left -x, down +y,
    /// up -y). A plain bool (not a `Keys2d`-style per-direction mapping) because the
    /// d-pad's four directions are a fixed, canonical set — there is exactly one
    /// d-pad, unlike the keyboard where content chooses which keys map to which
    /// direction — so "use the d-pad as a directional composite" is the whole binding,
    /// analogous to `pad_stick` naming a whole stick at once.
    pad_dpad: bool = false,
    /// Radial dead-zone applied to a native analog source before it reaches script
    /// (ADR 0040 §4). Meaningless for `button` actions; `validate` does not police it
    /// there (a stray `deadzone` on a button action is harmless, not an error).
    deadzone: f32 = default_deadzone,
};

/// One named action binding — `name` is the content-declared action identifier (the
/// ZON key), never a value `src/**` names (invariant #6).
pub const Binding = struct {
    name: []const u8,
    action: RawAction,
};

/// The parsed, validated `input.zon` binding table (ADR 0040 §3). Read-only config
/// loaded once at package-load time — not per-tick state, so it is never part of
/// `Sim`/`World`'s `stateHash` (mirroring `Sim.tilemap`). Owns `bindings` and every
/// string/slice reachable from it; free with `free` (in `action_parse.zig`). A `Sim`
/// stores a borrowed `*const ActionMap` (`Sim.action_map`), so the value returned by
/// `parse` must outlive any `Sim` pointed at it.
pub const ActionMap = struct {
    bindings: []const Binding = &.{},

    /// The binding for `name`, or null if `input.zon` declares no such action. Linear
    /// scan — action counts are small (tens, not thousands) and this runs at load
    /// time or from content tooling, never the per-tick hot path.
    pub fn find(self: ActionMap, name: []const u8) ?RawAction {
        for (self.bindings) |b| {
            if (std.mem.eql(u8, b.name, name)) return b.action;
        }
        return null;
    }
};

/// Errors `parse` can return. `OutOfMemory` is allocator failure. `ParseZon` covers
/// every structural/type problem `std.zon.parse` itself detects: malformed ZON syntax,
/// an `actions` entry that isn't a struct literal, or — the common case — an
/// unknown/misspelled `platform.Key`/`GamepadButton`/`GamepadAxis`/`Stick` enum tag
/// (an unrecognized source name never reaches `validate`; `std.zon.parse` rejects it
/// first). `Unbound` is a `validate` failure: an action declares no source at all
/// (empty `keys`/`pad_buttons` and no pad_stick/pad_axis/keys_2d/keys_1d/pad_dpad,
/// depending on type). `WrongTypedSource` is a `validate` failure: a binding sets a
/// source field that belongs to a different `type` (ADR 0040 §1's one-way analog rule
/// — a `button` action can never carry `pad_stick`/`pad_axis`/`keys_2d`/`keys_1d`/
/// `pad_dpad`, and an analog action can never carry flat `keys`/`pad_buttons`).
pub const Error = error{ OutOfMemory, ParseZon, Unbound, WrongTypedSource };
