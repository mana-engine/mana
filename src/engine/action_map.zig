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
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const Vec2 = core.Vec2;
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

// --- The pure per-tick resolver (ADR 0040 §4) --------------------------------------
//
// Everything below maps a tick's `platform.InputSnapshot` (plus the previous tick's, for
// button edges) against a parsed binding to a per-action value. It is intentionally kept in
// the same file as the parser it resolves against — one cohesive "action map" concern — which
// pushes the module past the ~500-line soft limit; the resolver is small and self-contained
// and a sibling file would only add cross-file wiring for no cohesion gain (justifying
// comment per CLAUDE.md "exceed only with a justifying comment").
//
// **Every function here is a PURE function of its snapshot argument(s) and the binding** — no
// globals, no time, no randomness, no allocation whose ordering could affect output (ADR 0040
// §6). The same `(snapshot, prev_snapshot, binding)` always yields bit-identical results, and
// nothing here feeds `World.stateHash` (the resolved value is derived per-tick from the
// hash-excluded snapshot). Multi-source ties are broken by a fixed binding order (native analog
// source before the key composite), never by hash-map iteration order.

/// A `button` action's transition between two consecutive ticks (ADR 0040 §4): `.pressed` on
/// the down edge, `.released` on the up edge, `.none` when the combined held-state is
/// unchanged. Mirrors the `on_key` `pressed` flag (ADR 0021), collapsed to one value.
pub const ButtonEdge = enum { none, pressed, released };

/// Magnitude (Euclidean length) of `v`. PURE.
fn magnitude(v: Vec2) f32 {
    return @sqrt(Vec2.dot(v, v));
}

/// Clamp `v` to unit length: pass it through unchanged when `|v| <= 1`, else normalize to
/// exactly length 1 (ADR 0040 §4 "normalize only when magnitude exceeds 1"). This is what
/// keeps a diagonal key combo (raw length √2) from being faster than a straight input, while
/// leaving an in-range stick magnitude untouched. PURE.
fn clampToUnit(v: Vec2) Vec2 {
    const m = magnitude(v);
    if (m <= 1.0) return v;
    return v.scale(1.0 / m);
}

/// Apply a RADIAL dead-zone (ADR 0040 §4): zero the vector when its *magnitude* is within
/// `dz`, else return it unchanged (a hard radial cutoff — the value just outside the radius
/// "passes through"). Radial means the test is on `|v|`, not per-component: a diagonal just
/// inside the radius is zeroed even if each component alone would clear a per-axis threshold.
/// Applied only to native analog sources (a synthesized key vector is already clean). PURE.
fn applyDeadzone(v: Vec2, dz: f32) Vec2 {
    if (magnitude(v) <= dz) return Vec2.zero;
    return v;
}

/// 1 when any key in `group` is held in `snap`, else 0 — the OR that lets several physical
/// keys drive one direction (e.g. both arrows and WASD). PURE.
fn groupBit(group: []const platform.Key, snap: platform.InputSnapshot) f32 {
    for (group) |key| if (snap.keys.contains(key)) return 1;
    return 0;
}

/// The raw `(x, y)` of a native stick in `snap` (before dead-zone / clamp). PURE.
fn stickVec(stick: Stick, snap: platform.InputSnapshot) Vec2 {
    return switch (stick) {
        .left => .{ .x = snap.pad_axes.get(.left_x), .y = snap.pad_axes.get(.left_y) },
        .right => .{ .x = snap.pad_axes.get(.right_x), .y = snap.pad_axes.get(.right_y) },
    };
}

/// Synthesize an `axis2d` vector from a held-key composite (ADR 0040 §4): each direction group
/// is OR'd, held opposites cancel, and the raw vector (components in {-1, 0, +1}) is clamped to
/// unit length so a diagonal is not √2 faster than a straight press. Sign convention matches
/// `src/engine/input.zig`: right = +x, left = −x, down = +y, up = −y. No dead-zone — a
/// synthesized vector is already clean. PURE.
fn synthAxis2d(k: Keys2d, snap: platform.InputSnapshot) Vec2 {
    const v: Vec2 = .{
        .x = groupBit(k.right, snap) - groupBit(k.left, snap),
        .y = groupBit(k.down, snap) - groupBit(k.up, snap),
    };
    return clampToUnit(v);
}

/// Synthesize an `axis1d` value from a held `pos`/`neg` key pair (ADR 0040 §4): `pos` held ⇒
/// +1, `neg` held ⇒ −1, both or neither ⇒ 0. PURE.
fn synthAxis1d(k: Keys1d, snap: platform.InputSnapshot) f32 {
    return groupBit(k.pos, snap) - groupBit(k.neg, snap);
}

/// Whether `action`'s combined button state is held in `snap` — the logical **OR** of every
/// bound source (keyboard keys and gamepad buttons), which is what makes the action
/// device-agnostic (any bound input holds it). A non-`button` action, or one whose flat
/// sources are empty, is never held. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveButtonHeld(action: RawAction, snap: platform.InputSnapshot) bool {
    for (action.keys) |k| if (snap.keys.contains(k)) return true;
    for (action.pad_buttons) |b| if (snap.pad_buttons.contains(b)) return true;
    return false;
}

/// The `button` edge for `action` between `prev` and `snap`. Edge detection is on the
/// **OR-combined** held-state (ADR 0040 §4): releasing one bound source while another stays
/// held does NOT fire `.released`, because the OR is still true. `.pressed` on the combined
/// down transition, `.released` on the up transition, else `.none`. PURE function of
/// `(action, snap, prev)`; `action` is borrowed.
pub fn resolveButtonEdge(action: RawAction, snap: platform.InputSnapshot, prev: platform.InputSnapshot) ButtonEdge {
    const cur = resolveButtonHeld(action, snap);
    const was = resolveButtonHeld(action, prev);
    if (cur == was) return .none;
    return if (cur) .pressed else .released;
}

/// Resolve an `axis2d` action to its `(x, y)` value (ADR 0040 §4). Candidate sources are
/// evaluated in a fixed binding order — the native `pad_stick` first, then the `keys_2d`
/// composite — and the source with the **greatest magnitude** this tick wins (a resting stick
/// never overrides active keys, and vice-versa). An exact magnitude tie is broken toward the
/// earlier source (the native stick), the deterministic §4 tie-break. The native stick has the
/// per-action radial `deadzone` applied *before* comparison; both candidates are clamped to
/// unit length (so a stick beyond magnitude 1 clamps to 1). A non-`axis2d` action, or one with
/// no analog source, resolves to zero. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveAxis2d(action: RawAction, snap: platform.InputSnapshot) Vec2 {
    var best: Vec2 = Vec2.zero;
    var best_mag: f32 = -1;
    // Binding order: native stick first, then synthesized keys (tie → earlier candidate wins,
    // since a later candidate only replaces on a *strictly* greater magnitude).
    if (action.pad_stick) |stick| {
        const v = clampToUnit(applyDeadzone(stickVec(stick, snap), action.deadzone));
        const m = magnitude(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    if (action.keys_2d) |k| {
        const v = synthAxis2d(k, snap);
        const m = magnitude(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    return best;
}

/// Resolve an `axis1d` action to its `f32` value (ADR 0040 §4). Same multi-source rule as
/// `resolveAxis2d`, in one dimension: the native `pad_axis` (a trigger in [0, 1] or a stick
/// axis in [-1, 1]) vs the `pos`/`neg` key pair synthesized to {-1, 0, +1}; the source with the
/// greater `|value|` wins, ties broken toward the native axis (binding order). The native axis
/// has the radial dead-zone (in 1-D, `|value| <= deadzone` ⇒ 0) applied and is clamped to
/// [-1, 1] (the 1-D "normalize when magnitude > 1"). A non-`axis1d` action, or one with no
/// analog source, resolves to 0. PURE function of `(action, snap)`; `action` is borrowed.
pub fn resolveAxis1d(action: RawAction, snap: platform.InputSnapshot) f32 {
    var best: f32 = 0;
    var best_mag: f32 = -1;
    if (action.pad_axis) |axis| {
        var v = snap.pad_axes.get(axis);
        if (@abs(v) <= action.deadzone) v = 0;
        v = std.math.clamp(v, -1, 1);
        const m = @abs(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    if (action.keys_1d) |k| {
        const v = synthAxis1d(k, snap);
        const m = @abs(v);
        if (m > best_mag) {
            best = v;
            best_mag = m;
        }
    }
    return best;
}

// --- Poll-facing entry points, keyed by action NAME (ADR 0040 §2) ------------------
//
// These look a binding up by name in the `ActionMap` and delegate to the `resolve*` core
// above — the exact shape the #218 `mana.action_down`/`action_axis`/`action_vector` polls
// will call. An unknown action name (or a poll of the wrong value-type) reads as the neutral
// value (not held / 0 / zero-vector); type-vs-poll validation is #218's job, not the pure
// resolver's. All PURE, all borrow `map`/`name`.

/// Is the named `button` action held this tick — the device-agnostic held poll (ADR 0040 §2).
/// Unknown name ⇒ false. Delegates to `resolveButtonHeld`.
pub fn buttonHeld(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) bool {
    const action = map.find(name) orelse return false;
    return resolveButtonHeld(action, snap);
}

/// The named `button` action's edge between `prev` and `snap` (ADR 0040 §4). Unknown name ⇒
/// `.none`. Delegates to `resolveButtonEdge`.
pub fn buttonEdge(map: ActionMap, snap: platform.InputSnapshot, prev: platform.InputSnapshot, name: []const u8) ButtonEdge {
    const action = map.find(name) orelse return .none;
    return resolveButtonEdge(action, snap, prev);
}

/// The named `axis1d` action's value this tick (ADR 0040 §2). Unknown name ⇒ 0. Delegates to
/// `resolveAxis1d`.
pub fn axis1d(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) f32 {
    const action = map.find(name) orelse return 0;
    return resolveAxis1d(action, snap);
}

/// The named `axis2d` action's value this tick (ADR 0040 §2). Unknown name ⇒ zero. Delegates
/// to `resolveAxis2d`.
pub fn axis2d(map: ActionMap, snap: platform.InputSnapshot, name: []const u8) Vec2 {
    const action = map.find(name) orelse return Vec2.zero;
    return resolveAxis2d(action, snap);
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

// --- Resolver tests (ADR 0040 §4) --------------------------------------------------

/// 1/√2 — the per-component value of a normalized diagonal.
const inv_sqrt2: f32 = 0.7071067811865476;

/// A four-direction `axis2d` key composite (arrow keys), shared by the axis2d tests.
const arrows: Keys2d = .{ .up = &.{.up}, .down = &.{.down}, .left = &.{.left}, .right = &.{.right} };

/// A snapshot with exactly `keys` held (no gamepad) — the injected-keyboard fixture.
fn keySnap(keys: []const platform.Key) platform.InputSnapshot {
    var s: platform.InputSnapshot = .{};
    for (keys) |k| s.keys.insert(k);
    return s;
}

test "resolver axis2d: a single held direction is a unit vector (right=+x, up=-y)" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    try testing.expectEqual(Vec2{ .x = 1, .y = 0 }, resolveAxis2d(move, keySnap(&.{.right})));
    try testing.expectEqual(Vec2{ .x = -1, .y = 0 }, resolveAxis2d(move, keySnap(&.{.left})));
    try testing.expectEqual(Vec2{ .x = 0, .y = -1 }, resolveAxis2d(move, keySnap(&.{.up})));
    try testing.expectEqual(Vec2{ .x = 0, .y = 1 }, resolveAxis2d(move, keySnap(&.{.down})));
}

test "resolver axis2d: held opposites cancel to zero" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .left, .right })));
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .up, .down })));
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, keySnap(&.{ .up, .down, .left, .right })));
}

test "resolver axis2d: a diagonal key combo normalizes to magnitude 1 (~0.707), not √2" {
    const move: RawAction = .{ .type = .axis2d, .keys_2d = arrows };
    const v = resolveAxis2d(move, keySnap(&.{ .up, .right }));
    try testing.expectApproxEqAbs(@as(f32, 1), magnitude(v), 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.x, 1e-5);
    try testing.expectApproxEqAbs(-inv_sqrt2, v.y, 1e-5);
}

test "resolver axis2d: a native stick at in-range magnitude passes through un-normalized" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 0.5); // > default_deadzone (0.15)
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 0.5), v.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v.y, 1e-6);
}

test "resolver axis2d: a native stick beyond magnitude 1 clamps to 1" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 1.0);
    s.pad_axes.set(.left_y, 1.0); // raw magnitude √2
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 1), magnitude(v), 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.x, 1e-5);
    try testing.expectApproxEqAbs(inv_sqrt2, v.y, 1e-5);
}

test "resolver axis1d: pos only = +1, neg only = -1, both = 0" {
    const thr: RawAction = .{ .type = .axis1d, .keys_1d = .{ .pos = &.{.w}, .neg = &.{.s} } };
    try testing.expectEqual(@as(f32, 1), resolveAxis1d(thr, keySnap(&.{.w})));
    try testing.expectEqual(@as(f32, -1), resolveAxis1d(thr, keySnap(&.{.s})));
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, keySnap(&.{ .w, .s })));
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, keySnap(&.{})));
}

test "resolver axis1d: a native trigger inside the dead-zone reads 0, outside passes through" {
    const thr: RawAction = .{ .type = .axis1d, .pad_axis = .right_trigger, .deadzone = 0.15 };
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.right_trigger, 0.1); // < 0.15
    try testing.expectEqual(@as(f32, 0), resolveAxis1d(thr, s));
    s.pad_axes.set(.right_trigger, 0.6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), resolveAxis1d(thr, s), 1e-6);
}

test "resolver button: held is the OR across key and pad sources; both must clear" {
    const jump: RawAction = .{ .type = .button, .keys = &.{.space}, .pad_buttons = &.{.south} };
    try testing.expect(resolveButtonHeld(jump, keySnap(&.{.space}))); // key alone
    var pad: platform.InputSnapshot = .{ .pad_connected = true };
    pad.pad_buttons.insert(.south);
    try testing.expect(resolveButtonHeld(jump, pad)); // pad alone
    var both = pad;
    both.keys.insert(.space);
    try testing.expect(resolveButtonHeld(jump, both)); // both
    try testing.expect(!resolveButtonHeld(jump, .{})); // neither
}

test "resolver button: no up-edge when one source releases while another stays held" {
    const jump: RawAction = .{ .type = .button, .keys = &.{.space}, .pad_buttons = &.{.south} };
    // prev: key + pad both held.
    var prev: platform.InputSnapshot = .{ .pad_connected = true };
    prev.keys.insert(.space);
    prev.pad_buttons.insert(.south);
    // now: key released, pad still held → OR still true → NO edge (the key case that must not fire).
    var pad_only: platform.InputSnapshot = .{ .pad_connected = true };
    pad_only.pad_buttons.insert(.south);
    try testing.expectEqual(ButtonEdge.none, resolveButtonEdge(jump, pad_only, prev));
    // releasing the last source fires .released.
    try testing.expectEqual(ButtonEdge.released, resolveButtonEdge(jump, .{}, prev));
    // a fresh press fires .pressed.
    try testing.expectEqual(ButtonEdge.pressed, resolveButtonEdge(jump, prev, .{}));
}

test "resolver analog multi-source: the greatest-magnitude source wins" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = arrows };
    // Resting stick + active keys → keys win.
    var s1: platform.InputSnapshot = .{ .pad_connected = true };
    s1.keys.insert(.right);
    try testing.expectEqual(Vec2{ .x = 1, .y = 0 }, resolveAxis2d(move, s1));
    // Active stick + resting keys → stick wins.
    var s2: platform.InputSnapshot = .{ .pad_connected = true };
    s2.pad_axes.set(.left_x, 0.9);
    const v2 = resolveAxis2d(move, s2);
    try testing.expectApproxEqAbs(@as(f32, 0.9), v2.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), v2.y, 1e-6);
}

test "resolver analog multi-source: an exact magnitude tie is broken by binding order (native first)" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = arrows };
    // Stick full +x (mag 1) and keys full +y (mag 1) — a deliberate tie. Native (stick) is the
    // earlier binding, so it wins: the result must be the stick's (1, 0), not the keys' (0, 1).
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 1.0);
    s.keys.insert(.down);
    const v = resolveAxis2d(move, s);
    try testing.expectApproxEqAbs(@as(f32, 1), v.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), v.y, 1e-5);
}

test "resolver dead-zone is RADIAL: a diagonal inside the radius zeroes; just outside passes" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left, .deadzone = 0.5 };
    // Diagonal inside the radius: each component 0.35 (would clear a 0.3 *per-axis* threshold),
    // but |v| ≈ 0.495 < 0.5 → a radial dead-zone zeroes it (a per-axis one would not).
    var inside: platform.InputSnapshot = .{ .pad_connected = true };
    inside.pad_axes.set(.left_x, 0.35);
    inside.pad_axes.set(.left_y, 0.35);
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, inside));
    // Just outside: |v| ≈ 0.566 > 0.5 → passes through unchanged.
    var outside: platform.InputSnapshot = .{ .pad_connected = true };
    outside.pad_axes.set(.left_x, 0.4);
    outside.pad_axes.set(.left_y, 0.4);
    const v = resolveAxis2d(move, outside);
    try testing.expectApproxEqAbs(@as(f32, 0.4), v.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), v.y, 1e-6);
}

test "resolver dead-zone: the engine default applies when the binding omits `deadzone`" {
    const move: RawAction = .{ .type = .axis2d, .pad_stick = .left }; // deadzone = default_deadzone
    try testing.expectEqual(@as(f32, 0.15), move.deadzone);
    var s: platform.InputSnapshot = .{ .pad_connected = true };
    s.pad_axes.set(.left_x, 0.1); // < 0.15 → zeroed
    try testing.expectEqual(Vec2.zero, resolveAxis2d(move, s));
    s.pad_axes.set(.left_x, 0.2); // > 0.15 → passes
    try testing.expectApproxEqAbs(@as(f32, 0.2), resolveAxis2d(move, s).x, 1e-6);
}

test "resolver: deterministic — same snapshot resolves identically via both entry points" {
    const src: [:0]const u8 =
        \\.{
        \\    .actions = .{
        \\        .move = .{ .type = .axis2d, .pad_stick = .left, .keys_2d = .{ .up = .{.up}, .down = .{.down}, .left = .{.left}, .right = .{.right} } },
        \\        .jump = .{ .type = .button, .keys = .{.space}, .pad_buttons = .{.south} },
        \\    },
        \\}
    ;
    const gpa = testing.allocator;
    const map = try parse(gpa, src);
    defer free(gpa, map);

    var snap: platform.InputSnapshot = .{ .pad_connected = true };
    snap.keys.insert(.right);
    snap.keys.insert(.space);
    snap.pad_axes.set(.left_x, 0.8);

    const move = map.find("move").?;
    const a = resolveAxis2d(move, snap);
    const b = axis2d(map, snap, "move"); // the name-keyed entry point
    const c = resolveAxis2d(move, snap); // resolve twice → bit-identical
    try testing.expectEqual(a, b);
    try testing.expectEqual(a, c);

    const jump = map.find("jump").?;
    try testing.expectEqual(resolveButtonHeld(jump, snap), buttonHeld(map, snap, "jump"));

    // Unknown action names read as the neutral value on every poll (type/name validation is #218).
    try testing.expect(!buttonHeld(map, snap, "no_such_action"));
    try testing.expectEqual(@as(f32, 0), axis1d(map, snap, "no_such_action"));
    try testing.expectEqual(Vec2.zero, axis2d(map, snap, "no_such_action"));
    try testing.expectEqual(ButtonEdge.none, buttonEdge(map, snap, snap, "no_such_action"));
}
