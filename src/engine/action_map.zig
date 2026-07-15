//! The data-driven action-binding table (ADR 0040 §3–§4): the module root for the whole
//! action-map concern, re-exporting its three sibling files so the public API is a single
//! `action_map.*` surface. Actions are content-named — nothing in `src/**` hardcodes an action
//! name (invariant #6); the namespace is entirely whatever a game's `input.zon` declares. A
//! `Sim` stores a borrowed `*const ActionMap` (`Sim.action_map`), exactly like `Sim.tilemap`.
//!
//! Split per issue #217 (this file reached 808 lines, over the ~500 soft limit) — the exact
//! pattern #151 applied to `ui.zig`: the shared leaf types, the parser, and the pure resolver
//! each live in their own sibling file, and this root `pub const`-re-exports every public symbol
//! so callers (`runtime/main.zig`'s load path, `sim.zig`, #218's script polls) name
//! `engine.action_map.parse` / `engine.action_map.buttonHeld` / `engine.ActionMap` unchanged:
//!
//! - `action_types.zig` — the plain-data leaf types both siblings build against (`RawAction`,
//!   `ActionMap`, `Keys2d`/`Keys1d`, `Stick`, `ActionType`, `Binding`, `default_deadzone`,
//!   `Error`). Factored out so neither the parser nor the resolver needs a back-`@import` of the
//!   other.
//! - `action_parse.zig` — `input.zon` → validated `ActionMap` (`parse`/`free`; ADR 0040 §3,
//!   issue #216). Parsing and validation only.
//! - `action_resolve.zig` — the pure per-tick resolver `InputSnapshot` → per-action values
//!   (`resolve*` core + the name-keyed `buttonHeld`/`buttonEdge`/`axis1d`/`axis2d` polls;
//!   ADR 0040 §4, issue #217). Depends only on the leaf types; the parser never appears in the
//!   resolver path, so the split adds no circular wiring.
//!
//! No `mana.*` script surface lives here — that is issue #218, one tier up.

const types = @import("action_types.zig");
const parser = @import("action_parse.zig");
const resolver = @import("action_resolve.zig");

// Re-exported so the public API (`action_map.RawAction`, `action_map.parse`,
// `action_map.buttonHeld`, …) is unchanged by the split — see the file-top doc comment.
pub const ActionType = types.ActionType;
pub const Stick = types.Stick;
pub const Keys2d = types.Keys2d;
pub const Keys1d = types.Keys1d;
pub const default_deadzone = types.default_deadzone;
pub const RawAction = types.RawAction;
pub const Binding = types.Binding;
pub const ActionMap = types.ActionMap;
pub const Error = types.Error;

pub const parse = parser.parse;
pub const free = parser.free;

pub const ButtonEdge = resolver.ButtonEdge;
pub const resolveButtonHeld = resolver.resolveButtonHeld;
pub const resolveButtonEdge = resolver.resolveButtonEdge;
pub const resolveAxis2d = resolver.resolveAxis2d;
pub const resolveAxis1d = resolver.resolveAxis1d;
pub const buttonHeld = resolver.buttonHeld;
pub const buttonEdge = resolver.buttonEdge;
pub const axis1d = resolver.axis1d;
pub const axis2d = resolver.axis2d;

test {
    // A module's root pulls in its siblings' `test` blocks: reference each so the parser and
    // resolver tests run under `zig build test` through this root (as they did before the split).
    _ = types;
    _ = parser;
    _ = resolver;
}
