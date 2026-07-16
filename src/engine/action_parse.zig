//! The `input.zon` parser for the data-driven action-binding table (ADR 0040 §3; issue #216):
//! turns a package's `input.zon` contents into a validated `ActionMap` of action name →
//! physical-source binding. Owns *parsing and validation only* — the pure per-tick resolver is
//! `action_resolve.zig` (issue #217), the shared leaf types are `action_types.zig`, and neither
//! adds any `mana.*` script surface (issue #218). Public API is re-exported through
//! `action_map.zig`, so callers name `engine.action_map.parse`/`.free` unchanged.
//!
//! `input.zon`'s top level is `.{ .actions = .{ <name> = <binding>, … } }` — a struct
//! literal whose field names *are* the action names, so the set of names is unbounded
//! and unknown at comptime. `std.zon.parse` alone cannot decode that (it only ever
//! decodes into a fixed, comptime-known set of struct fields), so `parse` below walks
//! the `Zoir` (`std.zig.Ast` + `std.zig.ZonGen`, the same intermediate form
//! `std.zon.parse` itself builds) one level to read the `actions` object's field names,
//! then delegates each individual binding to `std.zon.parse.fromZoirNodeAlloc` into the
//! fixed-shape `RawAction` — so every per-field type check (an unknown/misspelled
//! `platform.Key`/`GamepadButton`/`GamepadAxis` source name) is still `std.zon.parse`'s
//! for free, and this module never reimplements a ZON parser.

const std = @import("std");
const data = @import("data");
const platform = @import("platform");
const types = @import("action_types.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

const ActionType = types.ActionType;
const Stick = types.Stick;
const RawAction = types.RawAction;
const Binding = types.Binding;
const ActionMap = types.ActionMap;
const Error = types.Error;
const default_deadzone = types.default_deadzone;

/// Parse NUL-terminated ZON `source` (an `input.zon` file's contents) into an
/// `ActionMap`. Every action is validated (see `Error`) before this returns — a
/// partially-valid file is never returned; on error, everything allocated so far is
/// freed. The result owns its allocations (`gpa`); free with `free`.
///
/// The `Ast`/`Zoir` intermediate tree and every `RawAction` `std.zon.parse` decodes
/// while walking it are built in a scratch arena, torn down when this function
/// returns — never returned or borrowed by the result. Only a validated action is
/// deep-copied (`dupeAction`) out of the arena into a `gpa`-owned `Binding`. This
/// (rather than freeing the `Ast`/`Zoir`/each `RawAction` piecemeal with `gpa`) sidesteps
/// a `std.zon.parse` footgun: `fromZoirNodeAlloc(..., diag, ...)` stores a *copy* of the
/// `Ast`/`Zoir` it was given onto `diag` for message-formatting, and `Diagnostics.deinit`
/// unconditionally frees that copy's backing storage — so a caller that also owns and
/// frees the same `Ast`/`Zoir` itself (as parsing many actions off one tree requires)
/// double-frees the moment a per-action `Diagnostics` is deinitialized. An arena needs no
/// such per-object bookkeeping: whatever `std.zon.parse` allocates (including a
/// diagnostic note on a type-check failure, otherwise orphaned when `diag` is `null`) is
/// reclaimed in the one `arena.deinit()` regardless.
pub fn parse(gpa: Allocator, source: [:0]const u8) Error!ActionMap {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ast = try Ast.parse(arena, source, .zon);
    const zoir = try ZonGen.generate(arena, ast, .{ .parse_str_lits = false });
    if (zoir.hasCompileErrors()) return error.ParseZon;

    // Top level: `.{ .actions = .{ … } }`. No `.actions` field ⇒ a package that
    // declares no actions yet — a valid, empty map, not an error (mirrors `hud`/
    // `script` being optional on the manifest).
    const actions_node = findField(zoir, .root, "actions") orelse return .{};

    const actions_fields = switch (actions_node.get(zoir)) {
        .struct_literal => |s| s,
        .empty_literal => return .{},
        else => return error.ParseZon, // `.actions` present but not an object
    };

    const bindings = try gpa.alloc(Binding, actions_fields.names.len);
    errdefer gpa.free(bindings);
    var filled: usize = 0;
    errdefer for (bindings[0..filled]) |b| {
        gpa.free(b.name);
        data.free(gpa, b.action);
    };

    for (actions_fields.names, 0..) |raw_name, i| {
        const name = try gpa.dupe(u8, raw_name.get(zoir));
        errdefer gpa.free(name);

        const val_idx = actions_fields.vals.at(@intCast(i));
        const arena_action = try std.zon.parse.fromZoirNodeAlloc(RawAction, arena, ast, zoir, val_idx, null, .{});
        try validate(arena_action);

        const action = try dupeAction(gpa, arena_action);
        errdefer data.free(gpa, action);

        bindings[i] = .{ .name = name, .action = action };
        filled = i + 1;
    }

    return .{ .bindings = bindings };
}

/// Deep-copy a `RawAction`'s owned slices from `a` into freshly `gpa`-allocated ones
/// (`a` itself may be arena-backed and about to be torn down, or borrowed from another
/// `ActionMap` this one must not alias). Plain-value fields (`type`, `pad_stick`,
/// `pad_axis`, `pad_dpad`, `deadzone`) are copied by value. `pub` so `action_map.zig`'s
/// override-merge (ADR 0041 §2, #236) can reuse it to build a fresh owned merged map.
pub fn dupeAction(gpa: Allocator, a: RawAction) Allocator.Error!RawAction {
    // Start from safe (default-empty/null) owned fields, so `data.free` on the
    // `errdefer` below is always valid no matter how far this got — it only ever
    // frees a field this function itself already allocated.
    var out: RawAction = .{
        .type = a.type,
        .pad_stick = a.pad_stick,
        .pad_axis = a.pad_axis,
        .pad_dpad = a.pad_dpad,
        .deadzone = a.deadzone,
    };
    errdefer data.free(gpa, out);

    out.keys = try gpa.dupe(platform.Key, a.keys);
    out.pad_buttons = try gpa.dupe(platform.GamepadButton, a.pad_buttons);

    if (a.keys_2d) |k| {
        const up = try gpa.dupe(platform.Key, k.up);
        errdefer gpa.free(up);
        const down = try gpa.dupe(platform.Key, k.down);
        errdefer gpa.free(down);
        const left = try gpa.dupe(platform.Key, k.left);
        errdefer gpa.free(left);
        const right = try gpa.dupe(platform.Key, k.right);
        out.keys_2d = .{ .up = up, .down = down, .left = left, .right = right };
    }
    if (a.keys_1d) |k| {
        const pos = try gpa.dupe(platform.Key, k.pos);
        errdefer gpa.free(pos);
        const neg = try gpa.dupe(platform.Key, k.neg);
        out.keys_1d = .{ .pos = pos, .neg = neg };
    }

    return out;
}

/// Free an `ActionMap` returned by `parse`.
pub fn free(gpa: Allocator, map: ActionMap) void {
    for (map.bindings) |b| {
        gpa.free(b.name);
        data.free(gpa, b.action);
    }
    gpa.free(map.bindings);
}

/// The value node bound to `field_name` on the struct literal at `node`, or null if
/// `node` isn't a struct literal or has no such field. First match (ZON, like Zig,
/// does not allow duplicate struct-literal field names, so there is at most one).
fn findField(zoir: Zoir, node: Zoir.Node.Index, field_name: []const u8) ?Zoir.Node.Index {
    const s = switch (node.get(zoir)) {
        .struct_literal => |s| s,
        else => return null,
    };
    for (s.names, 0..) |n, i| {
        if (std.mem.eql(u8, n.get(zoir), field_name)) return s.vals.at(@intCast(i));
    }
    return null;
}

/// Reject a `RawAction` that binds a source belonging to another `type`
/// (`error.WrongTypedSource`) or binds no source at all (`error.Unbound`). See
/// `Error`'s doc comment for the exact rules. `pad_dpad` is `axis2d`-only (ADR 0040 §4
/// amendment, #230), mirroring `pad_stick`/`keys_2d`. `pub` so `action_map.zig`'s
/// override-merge (ADR 0041 §2, #236) can re-run the same one-way-analog-rule check
/// on an override binding, rather than duplicating it.
pub fn validate(a: RawAction) Error!void {
    const has_flat = a.keys.len != 0 or a.pad_buttons.len != 0;
    switch (a.type) {
        .button => {
            if (a.pad_stick != null or a.pad_axis != null or a.keys_2d != null or a.keys_1d != null or a.pad_dpad)
                return error.WrongTypedSource;
            if (!has_flat) return error.Unbound;
        },
        .axis2d => {
            if (has_flat or a.pad_axis != null or a.keys_1d != null)
                return error.WrongTypedSource;
            if (a.pad_stick == null and a.keys_2d == null and !a.pad_dpad) return error.Unbound;
        },
        .axis1d => {
            if (has_flat or a.pad_stick != null or a.keys_2d != null or a.pad_dpad)
                return error.WrongTypedSource;
            if (a.pad_axis == null and a.keys_1d == null) return error.Unbound;
        },
    }
}

// --- Tests -------------------------------------------------------------------------

const testing = std.testing;

test "action_map: parses a button, an axis2d (pad_stick + keys_2d), and an axis1d (pad_axis + keys_1d + deadzone)" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_buttons = .{.south} },
        \\        .move = .{
        \\            .type = .axis2d,
        \\            .pad_stick = .left,
        \\            .keys_2d = .{ .up = .{.up}, .down = .{.down}, .left = .{.left}, .right = .{.right} },
        \\            .deadzone = 0.2,
        \\        },
        \\        .throttle = .{ .type = .axis1d, .pad_axis = .right_trigger, .keys_1d = .{ .pos = .{.w}, .neg = .{.s} } },
        \\    },
        \\}
    ;
    const gpa = testing.allocator;
    const map = try parse(gpa, src);
    defer free(gpa, map);

    try testing.expectEqual(@as(usize, 3), map.bindings.len);

    const jump = map.find("jump").?;
    try testing.expectEqual(ActionType.button, jump.type);
    try testing.expectEqualSlices(platform.Key, &.{.space}, jump.keys);
    try testing.expectEqualSlices(platform.GamepadButton, &.{.south}, jump.pad_buttons);
    try testing.expectEqual(default_deadzone, jump.deadzone); // omitted ⇒ engine default

    const move = map.find("move").?;
    try testing.expectEqual(ActionType.axis2d, move.type);
    try testing.expectEqual(Stick.left, move.pad_stick.?);
    try testing.expectEqualSlices(platform.Key, &.{.up}, move.keys_2d.?.up);
    try testing.expectEqualSlices(platform.Key, &.{.down}, move.keys_2d.?.down);
    try testing.expectEqualSlices(platform.Key, &.{.left}, move.keys_2d.?.left);
    try testing.expectEqualSlices(platform.Key, &.{.right}, move.keys_2d.?.right);
    try testing.expectEqual(@as(f32, 0.2), move.deadzone);

    const throttle = map.find("throttle").?;
    try testing.expectEqual(ActionType.axis1d, throttle.type);
    try testing.expectEqual(platform.GamepadAxis.right_trigger, throttle.pad_axis.?);
    try testing.expectEqualSlices(platform.Key, &.{.w}, throttle.keys_1d.?.pos);
    try testing.expectEqualSlices(platform.Key, &.{.s}, throttle.keys_1d.?.neg);

    try testing.expect(map.find("no_such_action") == null);
}

test "action_map: a file with no `.actions` field parses to an empty map" {
    const gpa = testing.allocator;
    const map = try parse(gpa, ".{}");
    defer free(gpa, map);
    try testing.expectEqual(@as(usize, 0), map.bindings.len);
}

test "action_map: an unknown/misspelled source enum tag is a ParseZon error" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.moonwalk} },
        \\    },
        \\}
    ;
    try testing.expectError(error.ParseZon, parse(testing.allocator, src));
}

test "action_map: an analog source on a button action is WrongTypedSource" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_stick = .left },
        \\    },
        \\}
    ;
    try testing.expectError(error.WrongTypedSource, parse(testing.allocator, src));
}

test "action_map: pad_dpad on a button action is WrongTypedSource" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_dpad = true },
        \\    },
        \\}
    ;
    try testing.expectError(error.WrongTypedSource, parse(testing.allocator, src));
}

test "action_map: an axis2d action bound to only pad_dpad is OK (not Unbound)" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .move = .{ .type = .axis2d, .pad_dpad = true },
        \\    },
        \\}
    ;
    const gpa = testing.allocator;
    const map = try parse(gpa, src);
    defer free(gpa, map);

    const move = map.find("move").?;
    try testing.expectEqual(ActionType.axis2d, move.type);
    try testing.expect(move.pad_dpad);
}

test "action_map: a flat key list on an axis2d action is WrongTypedSource" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .move = .{ .type = .axis2d, .keys = .{.up}, .pad_stick = .left },
        \\    },
        \\}
    ;
    try testing.expectError(error.WrongTypedSource, parse(testing.allocator, src));
}

test "action_map: an action with no bound source at all is Unbound" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .jump = .{ .type = .button },
        \\    },
        \\}
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, src));
}

test "action_map: an axis1d/axis2d action with neither a pad source nor a key composite is Unbound" {
    const axis1d_src: [:0]const u8 =
        \\.{ .actions = .{ .throttle = .{ .type = .axis1d } } }
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, axis1d_src));

    const axis2d_src: [:0]const u8 =
        \\.{ .actions = .{ .move = .{ .type = .axis2d } } }
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, axis2d_src));
}

test "action_map: an `.actions` value that isn't an object is a ParseZon error (malformed structure)" {
    const src: [:0]const u8 =
        \\.{ .actions = .{ 1, 2, 3 } }
    ;
    try testing.expectError(error.ParseZon, parse(testing.allocator, src));
}

test "action_map: a valid action followed by an invalid one frees the already-filled bindings (no leak)" {
    // Exercises the `errdefer for (bindings[0..filled])` cleanup branch with filled > 0:
    // `.good` fills bindings[0], then `.bad` (unbound) fails validate, so parse must free
    // the first binding's name+action (and the bindings slice) as it unwinds. The leak-
    // detecting testing allocator turns any missed free here into a test failure.
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .good = .{ .type = .button, .keys = .{.space} },
        \\        .bad = .{ .type = .button },
        \\    },
        \\}
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, src));
}
