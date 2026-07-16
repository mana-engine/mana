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

const std = @import("std");
const data = @import("data");
const types = @import("action_types.zig");
const parser = @import("action_parse.zig");
const resolver = @import("action_resolve.zig");

const Allocator = std.mem.Allocator;

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

/// Errors `merge` can return beyond `Allocator.Error`. `UnknownAction`: the override
/// names an action the package `input.zon` never declared — there is nothing to
/// replace. `TypeMismatch`: the override binds the same action name but a different
/// `ActionType` — an action's type is a content contract the script reads through
/// (ADR 0041 §2), never overridable. `Unbound`/`WrongTypedSource`: the override's own
/// binding fails `action_parse.validate`'s one-way-analog-rule check (re-run here
/// rather than assumed, so `merge` is correct even when its `override` argument was
/// hand-built rather than freshly parsed).
pub const MergeError = error{ UnknownAction, TypeMismatch, Unbound, WrongTypedSource, OutOfMemory };

/// Merge a user-override `ActionMap` OVER a package `ActionMap` (ADR 0041 §2, #236):
/// **per-action replace, override-wins.** For an action name present in `override`,
/// the override's binding wholly replaces the package binding for that action — every
/// source field (`keys`/`pad_buttons`/`pad_stick`/`keys_2d`/`keys_1d`/`pad_dpad`/
/// `deadzone`) comes from the override, never a per-source union with the package
/// default (a rebind must be able to *remove* a default binding: package `jump =
/// space`, override `jump = f` ⇒ effective `jump` is `f` only, not "space-or-f"). An
/// action absent from `override` inherits the package binding unchanged.
///
/// An action's `type` is never overridable — it is a content contract the script reads
/// through. An override entry naming an action the package doesn't declare
/// (`error.UnknownAction`), or whose `type` disagrees with the package action's `type`
/// (`error.TypeMismatch`), or that violates the one-way analog rule
/// (`error.Unbound`/`error.WrongTypedSource`, `validate` reused rather than
/// duplicated) is a load error. The caller keeps the last-good effective map on error
/// (ADR 0041 §3's last-good-wins spirit) — `merge` itself just reports the failure
/// cleanly; the reload retry loop is phase 3 (#237).
///
/// `override` is expected to be a *partial* `input.zon` — the same schema (ADR 0040
/// §3) with only the changed actions listed — parsed with the same `parse` used for
/// the package file, but `merge` assumes nothing about its provenance (a hand-built
/// `ActionMap` works too), so phase 3's reload path can call this again on freshly
/// re-parsed maps without any special-casing.
///
/// Returns a fresh `gpa`-owned `ActionMap`: every binding, package-inherited or
/// override-replaced, is deep-copied, so `pkg` and `override` may be freed
/// independently of the result (and of each other). Free the result with `free`,
/// exactly like a parsed map. On error nothing is allocated or leaked.
pub fn merge(gpa: Allocator, pkg: ActionMap, override: ActionMap) MergeError!ActionMap {
    // Validate every override entry up front, before any allocation, so an error here
    // never leaves a partially-built result to clean up.
    for (override.bindings) |ob| {
        parser.validate(ob.action) catch |err| switch (err) {
            error.Unbound, error.WrongTypedSource => |e| return e,
            // `validate` is a pure field-shape check — it never allocates or parses
            // ZON, so these two members of its shared `Error` set are unreachable here.
            error.OutOfMemory, error.ParseZon => unreachable,
        };
        const pkg_action = pkg.find(ob.name) orelse return error.UnknownAction;
        if (pkg_action.type != ob.action.type) return error.TypeMismatch;
    }

    const bindings = try gpa.alloc(Binding, pkg.bindings.len);
    errdefer gpa.free(bindings);
    var filled: usize = 0;
    errdefer for (bindings[0..filled]) |b| {
        gpa.free(b.name);
        data.free(gpa, b.action);
    };

    for (pkg.bindings, 0..) |pb, i| {
        const name = try gpa.dupe(u8, pb.name);
        errdefer gpa.free(name);
        const source = override.find(pb.name) orelse pb.action;
        const action = try parser.dupeAction(gpa, source);
        bindings[i] = .{ .name = name, .action = action };
        filled = i + 1;
    }

    return .{ .bindings = bindings };
}

pub const ButtonEdge = resolver.ButtonEdge;
pub const resolveButtonHeld = resolver.resolveButtonHeld;
pub const resolveButtonEdge = resolver.resolveButtonEdge;
pub const resolveAxis2d = resolver.resolveAxis2d;
pub const resolveAxis1d = resolver.resolveAxis1d;
pub const buttonHeld = resolver.buttonHeld;
pub const buttonEdge = resolver.buttonEdge;
pub const axis1d = resolver.axis1d;
pub const axis2d = resolver.axis2d;

// --- Merge tests (ADR 0041 §2, #236) ------------------------------------------------

const testing = std.testing;
const platform = @import("platform");

test "merge: override wholly replaces a listed action's binding (every source field); an unlisted action inherits the package default unchanged" {
    const gpa = testing.allocator;
    const pkg_src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_buttons = .{.south} },
        \\        .pause = .{ .type = .button, .keys = .{.escape} },
        \\    },
        \\}
    ;
    const pkg = try parse(gpa, pkg_src);
    defer free(gpa, pkg);

    // A *partial* override — only `jump` is listed, and it drops `pad_buttons` entirely.
    const override_src: [:0]const u8 =
        \\.{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }
    ;
    const override = try parse(gpa, override_src);
    defer free(gpa, override);

    const effective = try merge(gpa, pkg, override);
    defer free(gpa, effective);

    try testing.expectEqual(@as(usize, 2), effective.bindings.len);

    const jump = effective.find("jump").?;
    try testing.expectEqualSlices(platform.Key, &.{.enter}, jump.keys); // replaced, not unioned
    try testing.expectEqual(@as(usize, 0), jump.pad_buttons.len); // dropped, not inherited

    const pause = effective.find("pause").?;
    try testing.expectEqualSlices(platform.Key, &.{.escape}, pause.keys); // unlisted ⇒ unchanged
}

test "merge: override-wins — per-action replace can remove a default binding (package jump=space, override jump=f ⇒ effective jump is f only, not space-or-f)" {
    const gpa = testing.allocator;
    const pkg = try parse(gpa, ".{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }");
    defer free(gpa, pkg);
    const override = try parse(gpa, ".{ .actions = .{ .jump = .{ .type = .button, .keys = .{.enter} } } }");
    defer free(gpa, override);

    const effective = try merge(gpa, pkg, override);
    defer free(gpa, effective);

    const jump = effective.find("jump").?;
    try testing.expectEqualSlices(platform.Key, &.{.enter}, jump.keys);
}

test "merge: an override naming an action absent from the package is UnknownAction" {
    const gpa = testing.allocator;
    const pkg = try parse(gpa, ".{ .actions = .{ .jump = .{ .type = .button, .keys = .{.space} } } }");
    defer free(gpa, pkg);
    const override = try parse(gpa, ".{ .actions = .{ .crouch = .{ .type = .button, .keys = .{.a} } } }");
    defer free(gpa, override);

    try testing.expectError(error.UnknownAction, merge(gpa, pkg, override));
}

test "merge: an override whose type disagrees with the package action's type is TypeMismatch" {
    const gpa = testing.allocator;
    const pkg = try parse(gpa, ".{ .actions = .{ .move = .{ .type = .axis2d, .pad_dpad = true } } }");
    defer free(gpa, pkg);
    const override = try parse(gpa, ".{ .actions = .{ .move = .{ .type = .button, .keys = .{.space} } } }");
    defer free(gpa, override);

    try testing.expectError(error.TypeMismatch, merge(gpa, pkg, override));
}

test "merge: an override binding that violates the one-way analog rule is rejected (validate reused, not duplicated)" {
    // Hand-built rather than parsed: `parse` would already reject this at the override's
    // own load time, so this exercises `merge`'s own defensive re-validation directly —
    // load-bearing once phase 3 (#237) calls `merge` on maps it did not itself parse.
    const gpa = testing.allocator;
    const pkg: ActionMap = .{};
    var bindings = [_]Binding{
        .{ .name = "jump", .action = .{ .type = .button, .pad_stick = .left } },
    };
    const override: ActionMap = .{ .bindings = &bindings };

    try testing.expectError(error.WrongTypedSource, merge(gpa, pkg, override));
}

test {
    // A module's root pulls in its siblings' `test` blocks: reference each so the parser and
    // resolver tests run under `zig build test` through this root (as they did before the split).
    _ = types;
    _ = parser;
    _ = resolver;
}
