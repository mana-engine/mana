//! The data-driven action-binding table (ADR 0040 §3): parses a package's `input.zon`
//! into an in-memory map of action name → physical-source binding. Actions are
//! content-named — nothing in `src/**` hardcodes an action name (invariant #6); the
//! namespace is entirely whatever a game's `input.zon` declares. This module owns
//! *parsing and validation only*. It does not resolve an `InputSnapshot` into a
//! per-action value (the pure per-tick resolver is issue #217) and does not add any
//! `mana.*` script surface (issue #218) — a `Sim` merely stores a borrowed
//! `*const ActionMap`, exactly like `Sim.tilemap`.
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

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

/// An action's declared value type (ADR 0040 §1): `button` is digital (down/up, read
/// via `on_action`/`action_down`), `axis1d` is a single analog `f32`, `axis2d` an
/// analog `(x, y)` vector. The type dictates which of `RawAction`'s source fields are
/// legal — `validate` below enforces that a source never crosses type (analog stays
/// analog).
pub const ActionType = enum { button, axis1d, axis2d };

/// Which physical stick a `pad_stick` binding reads — the whole stick, x and y at
/// once (ADR 0040 §3).
pub const Stick = enum { left, right };

/// The four key-groups an `axis2d` action synthesizes into a vector (ADR 0040 §4):
/// held opposites cancel, the raw vector normalizes to unit length past magnitude 1.
/// Each group is a list because multiple physical keys may drive the same direction
/// (e.g. both arrow keys and WASD). Resolving these into a value is issue #217 — this
/// struct only stores the bound key lists.
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

/// One action's raw binding, exactly ADR 0040 §3's ZON shape: a `type` tag plus every
/// possible source field, flat (not a Zig tagged union) because that is the literal
/// on-disk shape the ADR pins. Only the fields matching `type` are meaningful —
/// `validate` rejects a binding that sets a field belonging to a different type (e.g.
/// `pad_stick` on a `button` action) or that binds nothing at all. `keys`/`pad_buttons`
/// are used by `button` actions only; `axis1d`/`axis2d` actions use `keys_1d`/`keys_2d`
/// instead (ADR 0040 §3's rejected-alternatives: a flat key list cannot express which
/// direction each key drives).
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
/// string/slice reachable from it; free with `free`. A `Sim` stores a borrowed
/// `*const ActionMap` (`Sim.action_map`), so the value returned here must outlive any
/// `Sim` pointed at it.
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
/// (empty `keys`/`pad_buttons` and no pad/keys_2d/keys_1d, depending on type).
/// `WrongTypedSource` is a `validate` failure: a binding sets a source field that
/// belongs to a different `type` (ADR 0040 §1's one-way analog rule — a `button`
/// action can never carry `pad_stick`/`pad_axis`/`keys_2d`/`keys_1d`, and an analog
/// action can never carry flat `keys`/`pad_buttons`).
pub const Error = error{ OutOfMemory, ParseZon, Unbound, WrongTypedSource };

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
/// (`a` itself may be arena-backed and about to be torn down). Plain-value fields
/// (`type`, `pad_stick`, `pad_axis`, `deadzone`) are copied by value.
fn dupeAction(gpa: Allocator, a: RawAction) Allocator.Error!RawAction {
    // Start from safe (default-empty/null) owned fields, so `data.free` on the
    // `errdefer` below is always valid no matter how far this got — it only ever
    // frees a field this function itself already allocated.
    var out: RawAction = .{
        .type = a.type,
        .pad_stick = a.pad_stick,
        .pad_axis = a.pad_axis,
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
/// `Error`'s doc comment for the exact rules.
fn validate(a: RawAction) Error!void {
    const has_flat = a.keys.len != 0 or a.pad_buttons.len != 0;
    switch (a.type) {
        .button => {
            if (a.pad_stick != null or a.pad_axis != null or a.keys_2d != null or a.keys_1d != null)
                return error.WrongTypedSource;
            if (!has_flat) return error.Unbound;
        },
        .axis2d => {
            if (has_flat or a.pad_axis != null or a.keys_1d != null)
                return error.WrongTypedSource;
            if (a.pad_stick == null and a.keys_2d == null) return error.Unbound;
        },
        .axis1d => {
            if (has_flat or a.pad_stick != null or a.keys_2d != null)
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
    const axis1d: [:0]const u8 =
        \\.{ .actions = .{ .throttle = .{ .type = .axis1d } } }
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, axis1d));

    const axis2d: [:0]const u8 =
        \\.{ .actions = .{ .move = .{ .type = .axis2d } } }
    ;
    try testing.expectError(error.Unbound, parse(testing.allocator, axis2d));
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
