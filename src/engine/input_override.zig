//! The engine-side rebinding **persistence driver** (ADR 0041 §4): read the bindings a
//! script accepted off its handler table, and write them to the user-override
//! `input.zon` (ADR 0041 §2) the load path (`loadEffectiveActionMap`, #236) merges over
//! the package map and the watch path (#237) re-reads.
//!
//! **Why this is Zig and not Lua.** A script cannot touch the filesystem — ADR 0003 §7's
//! `_ENV` allowlist removed `io`/`os`/`package` — and must not: the engine owns the
//! file, the script only proposes data (invariant #1). So persistence is the #135
//! settings pattern generalised: content accumulates plain values in handler-table
//! fields, an engine-side driver reads them (`Runtime.handlerFieldInt` /
//! `handlerFieldStrMap`) and writes ZON with `data.saveFile`. Nothing here is added to
//! the `mana` surface, so ADR 0003 §5's version gate does not move.
//!
//! **The handler-table contract** (`bindings_field`/`revision_field` below) is
//! engine-generic, exactly like the rest of the action-map machinery: it names no
//! action, no key, and no game (invariant #6) — it is "the set of bindings this package
//! proposes" and "a counter it bumps when that set changes". A package that declares
//! neither never persists anything, which is every package shipping today.
//!
//! **Determinism.** Wholly cosmetic and hash-excluded (ADR 0041 §5): a rebind changes
//! *which* physical input triggers an action, never what a triggered action does, so
//! nothing here enters `World.stateHash`. The write is sorted by action name, so the
//! same proposed set always produces byte-identical ZON — a file, and a diff, that do
//! not churn.
//!
//! **The seam is two-way** (ADR 0041 §4 amendment, #247): `seedBindings` pushes the
//! override that is on disk *into* the handler table at load, the exact inverse of the
//! `handlerFieldStrMap` read. Without it a script — which cannot read the file — starts
//! every session believing the player has rebound nothing, and the first whole-override
//! write of session 2 silently drops session 1's rebinds.
//!
//! Over the ~500-line soft limit (~330 lines of driver, the rest tests): the driver
//! itself is small, and splitting its tests — the `pad_`-prefix translation (in both
//! directions), the write/parse round trip, and the live-interpreter `OverrideWriter`
//! staircase — away from the code they pin would only scatter one small concern across
//! two files. The write half and the read-back half are one contract and must stay
//! within one screen of each other. Revisit if the driver itself grows (e.g. when #240
//! moves the override path).

const std = @import("std");
const data = @import("data");
const platform = @import("platform");
const script = @import("script");
const action_map = @import("action_map.zig");
const script_runtime = @import("script_runtime.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const RawAction = action_map.RawAction;
const Binding = action_map.Binding;
const ActionMap = action_map.ActionMap;

/// The handler-table field holding the bindings the script has accepted: a Lua table
/// mapping **action name → source string**, in the `on_input_captured` `source`
/// vocabulary (ADR 0041 §1.1 — a bare key name like `"space"`, or a `"pad_"`-prefixed
/// gamepad button like `"pad_south"`). It is the WHOLE override the player owns, not a
/// delta: what it lists is what the file lists, so clearing an entry reverts that
/// action to its package default on the next write.
///
/// Which is only true because the field is **two-way**: `seedBindings` fills it from the
/// override on disk before the session starts proposing anything (ADR 0041 §4 amendment,
/// #247). A delta was the alternative — the driver merging its write over the file — but
/// it leaves the script blind to its own bindings, so a content-side duplicate check
/// would keep validating against the shipped defaults. One field, seeded then written,
/// keeps "what the script holds" and "what the file says" the same sentence.
pub const bindings_field = "bindings";

/// The handler-table field holding an integer the script bumps whenever it changes
/// `bindings_field` — its "commit this" signal. The driver writes only when this value
/// differs from the last one it wrote, so a session that rebinds nothing does no I/O and
/// no allocation at all, and content (not the engine) decides *when* a rebind is
/// durable (on accept, or on an explicit Apply).
///
/// A revision rather than a per-poll diff of the table itself: comparing tables would
/// mean enumerating and allocating on every poll forever, for a change that happens a
/// handful of times per session. This mirrors #135's plain-int handler field exactly.
pub const revision_field = "bindings_revision";

/// What one `OverrideWriter.poll` did.
pub const Outcome = union(enum) {
    /// The script proposes no bindings at all (no `revision_field`), or has not bumped
    /// the revision since the last write. The overwhelmingly common case — no I/O, no
    /// allocation. Also the answer under a no-Lua build, where there is no handler table.
    unchanged,
    /// The override file was written; the payload is how many actions it now lists
    /// (0 when the player cleared every rebind — a legitimate write, reverting the
    /// package to its defaults).
    written: usize,
    /// The script proposed something unwritable (see `Reject`) — **nothing was
    /// written**, so the override on disk keeps its last-good contents (ADR 0041 §3's
    /// last-good-wins spirit, applied to the write side). The revision is consumed
    /// regardless, so a bad proposal is reported once, not re-attempted every poll.
    rejected: Reject,
};

/// Why a proposed binding set could not be written. Returned rather than logged so the
/// caller owns the message (the `script.lua.State.DispatchOutcome` precedent: the Zig
/// test runner fails any test that emits an `.err` log, so a leaf that reports instead
/// of logging is the testable one).
pub const Reject = enum {
    /// A source string names neither a `platform.Key` nor (after its `"pad_"` prefix)
    /// a `platform.GamepadButton` — a typo, or an analog source, which v1 capture never
    /// produces (ADR 0041 §1.1 defers analog).
    unknown_source,
    /// An action name is not a bare ZON identifier, so it cannot become a field name
    /// in `input.zon`. Writing it would produce a file the loader could only reject;
    /// refusing is the honest answer.
    invalid_action_name,
};

/// The persistence driver's own state: the revision already on disk (ADR 0041 §4).
/// Holds no allocation and borrows nothing — construct it with `init` next to the
/// `Runtime` it will poll, and it is valid for that session.
pub const OverrideWriter = struct {
    /// The `revision_field` value the current override file reflects. Read from the
    /// script at `init` rather than assumed 0, so a package whose script starts at a
    /// non-zero revision does not provoke a pointless rewrite on the first poll.
    /// `seedBindings` deliberately does not touch the revision, so seeding the loaded
    /// override into the handler table — the file it reflects is already on disk — never
    /// looks like a proposal to write (ADR 0041 §4 amendment, #247).
    last_revision: i64,

    /// Read `rt`'s current revision: whatever the script starts with is treated as
    /// already persisted. Call after the package script is loaded.
    pub fn init(rt: *script_runtime.Runtime) OverrideWriter {
        return .{ .last_revision = rt.handlerFieldInt(revision_field) orelse 0 };
    }

    /// If the script bumped `revision_field` since the last write, serialise
    /// `bindings_field` into `path` (relative to `dir`) as a partial `input.zon` and
    /// report `.written`; otherwise `.unchanged` (no I/O, no allocation).
    ///
    /// Call at a **tick boundary**: the write is what the watcher then picks up, and the
    /// resulting map swap must not land mid-tick (ADR 0041 §3). The write is what makes
    /// a rebind durable *and*, via that watch, what applies it — one motion (§4.3).
    ///
    /// A proposal the driver cannot faithfully write is `.rejected` and leaves the file
    /// untouched (see `Reject`). A proposal well-formed *here* but wrong against the
    /// package map (an unknown action, a `type` mismatch) is deliberately NOT policed
    /// here: `action_map.merge` is where ADR 0041 §2 puts that check, and the load path
    /// already logs it and keeps the last-good map.
    ///
    /// Errors: `OutOfMemory`, plus whatever `data.saveFile` reports — notably
    /// `FileNotFound` when `path`'s directory does not exist (the package supplies
    /// `save/`; the engine creates no directories, and #240 moves this path to the OS
    /// config dir anyway). A failed save is not fatal: nothing was persisted, the
    /// session plays on.
    pub fn poll(
        self: *OverrideWriter,
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        rt: *script_runtime.Runtime,
    ) !Outcome {
        const revision = rt.handlerFieldInt(revision_field) orelse return .unchanged;
        if (revision == self.last_revision) return .unchanged;
        self.last_revision = revision; // consumed either way: report a bad proposal once

        const proposed = try rt.handlerFieldStrMap(gpa, bindings_field);
        const pairs = proposed orelse return .unchanged;
        defer script_runtime.Runtime.freeStrMap(gpa, pairs);

        const map = buildOverrideMap(gpa, pairs) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.UnknownSource => return .{ .rejected = .unknown_source },
            error.InvalidActionName => return .{ .rejected = .invalid_action_name },
        };
        defer action_map.free(gpa, map);

        try writeOverride(gpa, io, dir, path, map);
        return .{ .written = map.bindings.len };
    }
};

/// Errors `buildOverrideMap` can return beyond `OutOfMemory` — the `Reject` cases,
/// as an error set so the build can bail on the first bad entry without a partial map.
pub const BuildError = error{ UnknownSource, InvalidActionName, OutOfMemory };

/// Turn proposed `action name → source string` pairs into an owned, *sorted* partial
/// `ActionMap` — the in-memory form of the override file (ADR 0041 §4).
///
/// **The `"pad_"` prefix is where the two source vocabularies meet** (ADR 0041 §1.1).
/// Capture reports keys as the bare `@tagName` (`"space"`, `"w"`) but gamepad buttons
/// `"pad_"`-prefixed (`"pad_south"`), because a flat string namespace has to encode the
/// source *kind* somehow. `input.zon` encodes the kind in the *field* instead: `keys`
/// holds bare `platform.Key` literals and `pad_buttons` bare `platform.GamepadButton`
/// literals (`.south`, never `.pad_south`). So a `"pad_"`-prefixed source is stripped
/// and routed to `pad_buttons`; every other source is a key and needs no translation.
/// No `platform.Key` tag begins with `pad_`, so the test is unambiguous.
///
/// Every source is digital, so every produced action is `.type = .button`: v1 capture
/// qualifies key and pad-button press edges only (ADR 0041 §1.1 defers analog capture).
/// A source proposed for an action the package typed `axis1d`/`axis2d` is therefore an
/// override `action_map.merge` rejects as a `TypeMismatch` — the right layer for it,
/// already logged + last-good-wins there.
///
/// Sorted by action name so the same proposed set always serialises byte-identically
/// (Lua's table order is an unspecified hash order, and a file a human reads and diffs
/// must not reshuffle itself on every save).
///
/// The result is `gpa`-owned (deep-copied out of `pairs`, which the caller may free
/// immediately); free it with `action_map.free`, exactly like a parsed map. On error
/// nothing is allocated or leaked.
pub fn buildOverrideMap(gpa: Allocator, pairs: []const script.StrPair) BuildError!ActionMap {
    const bindings = try gpa.alloc(Binding, pairs.len);
    errdefer gpa.free(bindings);
    var filled: usize = 0;
    errdefer for (bindings[0..filled]) |b| {
        gpa.free(b.name);
        data.free(gpa, b.action);
    };

    for (pairs, 0..) |p, i| {
        // The name becomes a ZON field name verbatim (`data.zon.Object`), so a name
        // that is not a bare identifier could only produce an unparseable file.
        if (!std.zig.isValidId(p.key)) return error.InvalidActionName;
        const action = try buildAction(gpa, p.value);
        errdefer data.free(gpa, action);
        const name = try gpa.dupe(u8, p.key);
        bindings[i] = .{ .name = name, .action = action };
        filled = i + 1;
    }

    std.mem.sort(Binding, bindings, {}, lessByName);
    return .{ .bindings = bindings };
}

fn lessByName(_: void, a: Binding, b: Binding) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// One captured `source` string → an owned single-source `button` binding. See
/// `buildOverrideMap` for the `"pad_"` prefix rule this implements.
fn buildAction(gpa: Allocator, source: []const u8) BuildError!RawAction {
    const pad_prefix = "pad_";
    if (std.mem.startsWith(u8, source, pad_prefix)) {
        const bare = source[pad_prefix.len..]; // `"pad_south"` → `.south`
        const button = std.meta.stringToEnum(platform.GamepadButton, bare) orelse return error.UnknownSource;
        return .{ .type = .button, .pad_buttons = try gpa.dupe(platform.GamepadButton, &.{button}) };
    }
    const key = std.meta.stringToEnum(platform.Key, source) orelse return error.UnknownSource;
    return .{ .type = .button, .keys = try gpa.dupe(platform.Key, &.{key}) };
}

/// Seed the script's `bindings_field` with the override that is actually on disk (ADR
/// 0041 §4 amendment, issue #247) — the **read-back seam**, and the reason the
/// whole-override write above is safe.
///
/// **Why it must exist.** `bindings_field` is the WHOLE override, not a delta, so the
/// driver can only write the truth if the script *holds* the truth. A script cannot load
/// the override itself — ADR 0003 §7 leaves it no filesystem — so without this push its
/// table starts empty every session, and the first rebind of session 2 writes a file
/// listing only that rebind, silently dropping session 1's. It also makes the script's
/// own validation (a duplicate check against what is currently bound) see *live*
/// bindings rather than the package defaults it shipped with.
///
/// **Never bumps `revision_field`.** A seed is the engine telling the script what is
/// already persisted, not a proposal to persist — so it provokes no write, and re-seeding
/// after a reload cannot loop against the watcher that observed the driver's own write.
/// That also makes re-seeding safe to do on every reload, which is what keeps a *hand
/// edit* of the override from being clobbered by the script's otherwise-stale set — for
/// the entries this can represent; see the lossiness note below for the ones it cannot.
///
/// `override` is the *override* map (`save/input.zon` parsed), **not** the effective
/// merged map: what the script holds is what the driver writes back, and writing the
/// merged map would freeze today's package defaults into the player's override file,
/// silently opting every action out of future content updates. An empty/absent override
/// therefore seeds an empty set — "the player has rebound nothing", which is exactly what
/// the file says.
///
/// **Lossy in one direction, by construction — and it says so.** Only entries
/// `buildOverrideMap` could have produced round-trip: a `button` action bound to exactly
/// one digital source (see `overrideSources`). A hand-written override entry outside that
/// domain (two keys on one action, an analog source) is not representable in the script's
/// one-source-per-action contract, so it is **not seeded — and a later rebind's
/// whole-override write drops it**. v1 capture cannot produce such an entry (ADR 0041
/// §1.1 defers analog), so this only bites an override hand-edited into a shape the remap
/// UI itself cannot express — but the override file is human-editable *by design* (ADR
/// 0041 §2) and watched (§3), so hand-editing is a sanctioned workflow, not a
/// never-happens. Every skip is therefore REPORTED (`Seed.skipped`) rather than swallowed:
/// this whole issue (#247) exists because the loss was silent, and a narrower silent loss
/// would just repeat that in miniature.
///
/// `rt` and `override` are borrowed for the call — except `Seed.skipped`'s names, which
/// borrow `override` and are valid only as long as it is. Errors: `OutOfMemory` only.
pub fn seedBindings(gpa: Allocator, rt: *script_runtime.Runtime, override: ActionMap) Allocator.Error!Seed {
    const pairs = try overrideSources(gpa, override);
    defer freeSources(gpa, pairs);
    rt.setHandlerFieldStrMap(bindings_field, pairs);
    return .{ .seeded = pairs.len, .skipped = try unseedableActions(gpa, override) };
}

/// What one `seedBindings` did — reported, not logged, so the caller owns the message
/// (the `Reject` precedent above: a leaf that reports is the testable one, and the Zig
/// test runner fails any test that emits an `.err` log).
pub const Seed = struct {
    /// How many of `override`'s entries reached the script's `bindings_field`.
    seeded: usize,
    /// The action names of the entries that did **not** — see `seedBindings`'s lossiness
    /// note; a later whole-override write will drop these. Empty in every case v1 capture
    /// can produce. The names **borrow the `override` map** passed to `seedBindings` (they
    /// are not copies); the slice itself is `gpa`-owned — free it with `gpa.free`, and
    /// never free the names.
    skipped: []const []const u8 = &.{},
};

/// The action names in `map` that `overrideSources` cannot represent, in `map` order —
/// the complement of what it returns, sharing `sourceOf` as the single definition of
/// "representable" so the two can never disagree.
///
/// Names borrow `map`; the slice is `gpa`-owned (free with `gpa.free`). Errors:
/// `OutOfMemory` only.
pub fn unseedableActions(gpa: Allocator, map: ActionMap) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var buf: [64]u8 = undefined;
    for (map.bindings) |b| {
        if (sourceOf(&buf, b.action) == null) try names.append(gpa, b.name);
    }
    return names.toOwnedSlice(gpa);
}

/// `buildOverrideMap`'s inverse: an override `ActionMap` → the `action name → source
/// string` pairs the script's `bindings_field` holds, in the capture vocabulary the
/// script emits (a bare key `@tagName`, a `"pad_"`-prefixed button — ADR 0041 §1.1). The
/// prefix goes back ON here, because the driver stripped it going the other way; a seed
/// in the wrong vocabulary would silently break the script's own comparisons.
///
/// An action the script's one-source-per-action contract cannot express is **skipped**,
/// not an error: `map` may have been hand-written (ADR 0041 §2 keeps the override
/// human-editable), and a session must still start with the entries it *can* represent
/// rather than refusing to seed at all. Skipped = anything but a `button` bound to
/// exactly one source across `keys`/`pad_buttons`.
///
/// The result and every string in it are `gpa`-owned copies (nothing borrows from `map`,
/// so it may be freed immediately) — free with `freeSources`, **not**
/// `script_runtime.Runtime.freeStrMap`: that one is the backend's to define and is inert
/// under a no-Lua build (where its read twin never allocates), whereas this allocates on
/// every build.
pub fn overrideSources(gpa: Allocator, map: ActionMap) Allocator.Error![]script.StrPair {
    var pairs: std.ArrayList(script.StrPair) = .empty;
    errdefer {
        for (pairs.items) |p| {
            gpa.free(p.key);
            gpa.free(p.value);
        }
        pairs.deinit(gpa);
    }

    var buf: [64]u8 = undefined; // longest is "pad_" + a GamepadButton tag
    for (map.bindings) |b| {
        const source = sourceOf(&buf, b.action) orelse continue;
        const key = try gpa.dupe(u8, b.name);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, source);
        errdefer gpa.free(value);
        try pairs.append(gpa, .{ .key = key, .value = value });
    }
    return pairs.toOwnedSlice(gpa);
}

/// Free an `overrideSources` result: every string in `pairs`, then `pairs` itself. `gpa`
/// must be the allocator that produced it.
pub fn freeSources(gpa: Allocator, pairs: []const script.StrPair) void {
    for (pairs) |p| {
        gpa.free(p.key);
        gpa.free(p.value);
    }
    gpa.free(pairs);
}

/// One binding → its capture-vocabulary source string (written into `buf`, which the
/// caller must keep alive until it copies the result), or null when the binding is not a
/// single-digital-source `button` — see `overrideSources`.
fn sourceOf(buf: []u8, a: RawAction) ?[]const u8 {
    if (a.type != .button) return null; // analog: v1 capture never produced it
    if (a.keys.len == 1 and a.pad_buttons.len == 0) return @tagName(a.keys[0]);
    if (a.keys.len == 0 and a.pad_buttons.len == 1) {
        // `std.fmt.bufPrint` cannot fail here: `buf` is 64 bytes and every
        // `"pad_" ++ @tagName(GamepadButton)` is far shorter.
        return std.fmt.bufPrint(buf, "pad_{s}", .{@tagName(a.pad_buttons[0])}) catch unreachable;
    }
    return null; // unbound, or more than one source: no one-string form exists
}

/// The override file's top level — `.{ .actions = .{ … } }` (ADR 0040 §3), with the
/// runtime-named `actions` object `data.zon.Object` exists for (an action name is
/// content's, never a comptime field `src/**` could name — invariant #6).
const OverrideFile = struct {
    actions: data.zon.Object(RawAction),
};

/// Serialise `map` to `path` (relative to `dir`) as a partial `input.zon` via
/// `data.saveFile` — the same shape, and the same file, the loader (#236) parses and
/// merges back. `map` is borrowed. Errors: as `data.saveFile`.
pub fn writeOverride(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, map: ActionMap) !void {
    const Field = data.zon.Object(RawAction).Field;
    const fields = try gpa.alloc(Field, map.bindings.len);
    defer gpa.free(fields);
    for (map.bindings, 0..) |b, i| fields[i] = .{ .name = b.name, .value = b.action };

    try data.saveFile(gpa, io, dir, path, OverrideFile{ .actions = .{ .fields = fields } });
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const core = @import("core");
const command = @import("command.zig");
const timer = @import("timer.zig");
const World = @import("world.zig").World;

test "input override: a captured KEY source round-trips — written as a bare `keys` literal the action-map parser reads back" {
    const gpa = testing.allocator;
    const map = try buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "space" }});
    defer action_map.free(gpa, map);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeOverride(gpa, testing.io, tmp.dir, "input.zon", map);

    // The round trip that matters: what the driver WRITES, the phase-2 loader PARSES.
    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const parsed = try action_map.parse(gpa, src);
    defer action_map.free(gpa, parsed);

    try testing.expectEqualDeep(map, parsed);
    const jump = parsed.find("jump").?;
    try testing.expectEqual(action_map.ActionType.button, jump.type);
    try testing.expectEqualSlices(platform.Key, &.{.space}, jump.keys); // bare, no translation
    try testing.expectEqual(@as(usize, 0), jump.pad_buttons.len);
}

test "input override: a captured PAD-BUTTON source has its `pad_` prefix stripped and lands in `pad_buttons`, not `keys`" {
    // The asymmetry ADR 0041 §1.1 pins: capture reports `"pad_south"`, but `input.zon`'s
    // `pad_buttons` list holds the BARE enum literal `.south`.
    const gpa = testing.allocator;
    const map = try buildOverrideMap(gpa, &.{.{ .key = "fire", .value = "pad_south" }});
    defer action_map.free(gpa, map);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeOverride(gpa, testing.io, tmp.dir, "input.zon", map);

    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    // The literal is `.south` — proving the prefix never reaches the file (`.pad_south`
    // is not a `GamepadButton` tag, so `parse` below would reject it outright).
    try testing.expect(std.mem.indexOf(u8, src, ".south") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pad_south") == null);

    const parsed = try action_map.parse(gpa, src);
    defer action_map.free(gpa, parsed);
    const fire = parsed.find("fire").?;
    try testing.expectEqualSlices(platform.GamepadButton, &.{.south}, fire.pad_buttons);
    try testing.expectEqual(@as(usize, 0), fire.keys.len); // routed to pad_buttons, not keys
}

test "input override: a multi-directional pad button (`pad_dpad_up`) strips only the `pad_` prefix" {
    // Regression against an over-eager strip: `dpad_up` is the bare tag, `dpad` is not.
    const gpa = testing.allocator;
    const map = try buildOverrideMap(gpa, &.{.{ .key = "up", .value = "pad_dpad_up" }});
    defer action_map.free(gpa, map);
    try testing.expectEqualSlices(platform.GamepadButton, &.{.dpad_up}, map.find("up").?.pad_buttons);
}

test "input override: the written file is sorted by action name, so the same proposed set always serialises identically" {
    const gpa = testing.allocator;
    // Two orderings of the same set — Lua hands them over in an unspecified hash order.
    const a = try buildOverrideMap(gpa, &.{
        .{ .key = "jump", .value = "space" },
        .{ .key = "fire", .value = "pad_south" },
    });
    defer action_map.free(gpa, a);
    const b = try buildOverrideMap(gpa, &.{
        .{ .key = "fire", .value = "pad_south" },
        .{ .key = "jump", .value = "space" },
    });
    defer action_map.free(gpa, b);

    try testing.expectEqualStrings("fire", a.bindings[0].name);
    try testing.expectEqualStrings("jump", a.bindings[1].name);
    try testing.expectEqualDeep(a, b);
}

test "input override: an unknown source, and an action name that is not a ZON identifier, are rejected before anything is written" {
    const gpa = testing.allocator;
    try testing.expectError(error.UnknownSource, buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "nosuchkey" }}));
    // An analog source: v1 capture never emits one (ADR 0041 §1.1), and it is not a button.
    try testing.expectError(error.UnknownSource, buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "pad_left_trigger" }}));
    // `.pad_south` is not a `GamepadButton` — an un-stripped prefix must not sneak through.
    try testing.expectError(error.UnknownSource, buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "pad_pad_south" }}));
    try testing.expectError(error.InvalidActionName, buildOverrideMap(gpa, &.{.{ .key = "not an id", .value = "space" }}));
}

test "input override: an empty proposed set writes an empty actions table the parser accepts (every rebind cleared ⇒ package defaults)" {
    const gpa = testing.allocator;
    const map = try buildOverrideMap(gpa, &.{});
    defer action_map.free(gpa, map);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeOverride(gpa, testing.io, tmp.dir, "input.zon", map);

    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const parsed = try action_map.parse(gpa, src);
    defer action_map.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.bindings.len);
}

test "input override: the written override merges over a package map — the rebound action is replaced, an untouched one is not" {
    // The end-to-end contract this driver exists to satisfy (ADR 0041 §4.3): what it
    // writes, `loadEffectiveActionMap`'s parse + merge turns into the live map.
    const gpa = testing.allocator;
    const pkg = try action_map.parse(gpa,
        \\.{ .actions = .{
        \\    .jump = .{ .type = .button, .keys = .{.space} },
        \\    .pause = .{ .type = .button, .keys = .{.escape} },
        \\} }
    );
    defer action_map.free(gpa, pkg);

    const proposed = try buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "enter" }});
    defer action_map.free(gpa, proposed);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeOverride(gpa, testing.io, tmp.dir, "input.zon", proposed);
    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const override = try action_map.parse(gpa, src);
    defer action_map.free(gpa, override);

    const effective = try action_map.merge(gpa, pkg, override);
    defer action_map.free(gpa, effective);
    try testing.expectEqualSlices(platform.Key, &.{.enter}, effective.find("jump").?.keys);
    try testing.expectEqualSlices(platform.Key, &.{.escape}, effective.find("pause").?.keys);
}

// The `OverrideWriter` tests below drive the REAL phase-1 → phase-4 seam: a capture
// delivery (`on_input_captured`, ADR 0041 §1) is what a content script reacts to by
// recording a binding, and the driver reads exactly that recorded state back. Nothing
// test-only sits between them.

/// The live-Sim context one `on_input_captured` dispatch needs. The handlers below queue
/// no mutations, so a bare world/command-buffer/timer/rng is the whole seam — mirroring
/// `ui_dispatch.zig`'s capture tests.
const CaptureFixture = struct {
    world: World,
    commands: command.CommandBuffer = .{},
    timers: timer.Timers = .{},
    rng: core.Rng = core.Rng.init(0),
    rt: script_runtime.Runtime = .{},

    fn init(gpa: Allocator, handlers: [:0]const u8) !*CaptureFixture {
        const self = try gpa.create(CaptureFixture);
        self.* = .{ .world = World.init(gpa) };
        try self.rt.loadHandlers(gpa, handlers);
        return self;
    }

    fn deinit(self: *CaptureFixture, gpa: Allocator) void {
        self.rt.deinit(gpa);
        self.timers.deinit(gpa);
        self.commands.deinit(gpa);
        self.world.deinit();
        gpa.destroy(self);
    }

    fn ctx(self: *CaptureFixture, gpa: Allocator) script_runtime.DispatchCtx {
        return .{
            .world = &self.world,
            .commands = &self.commands,
            .gpa = gpa,
            .now_seconds = 0,
            .timers = &self.timers,
            .rng = &self.rng,
        };
    }

    /// Deliver one capture, exactly as `ui_dispatch` does on a qualifying press edge.
    fn capture(self: *CaptureFixture, gpa: Allocator, action: []const u8, source: []const u8) !void {
        try self.rt.dispatchInputCaptured(action, source, self.ctx(gpa));
    }
};

/// The content shape ADR 0041 §4 describes: `on_input_captured` records the accepted
/// binding into plain handler-table state and bumps the revision — the script's
/// "persist this" signal. `games/menu`'s controls screen (phase 5, #239) is this.
const accepting_handlers =
    \\local t = { bindings = {}, bindings_revision = 0 }
    \\function t.on_input_captured(ev)
    \\  t.bindings[ev.action] = ev.source
    \\  t.bindings_revision = t.bindings_revision + 1
    \\end
    \\return t
;

test "input override: OverrideWriter persists an accepted rebind only when the script bumps the revision, and both source kinds survive the trip" {
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fx = try CaptureFixture.init(gpa, accepting_handlers);
    defer fx.deinit(gpa);

    // A session that rebinds nothing must never rewrite the file.
    var writer: OverrideWriter = .init(&fx.rt);
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "input.zon", .{}));

    // Two captures, one of each source kind (ADR 0041 §1.1's asymmetric vocabulary).
    try fx.capture(gpa, "jump", "enter"); // a key: bare `@tagName`
    try fx.capture(gpa, "fire", "pad_south"); // a pad button: `pad_`-prefixed
    try testing.expectEqual(Outcome{ .written = 2 }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    // Idempotent: a poll with no further rebind neither writes nor allocates.
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));

    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const parsed = try action_map.parse(gpa, src);
    defer action_map.free(gpa, parsed);
    try testing.expectEqualSlices(platform.Key, &.{.enter}, parsed.find("jump").?.keys);
    try testing.expectEqualSlices(platform.GamepadButton, &.{.south}, parsed.find("fire").?.pad_buttons);

    // A later rebind of an already-persisted action REPLACES it (per-action replace,
    // ADR 0041 §2) — the file is the whole set, never an append log.
    try fx.capture(gpa, "jump", "space");
    try testing.expectEqual(Outcome{ .written = 2 }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    const src2 = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src2);
    const parsed2 = try action_map.parse(gpa, src2);
    defer action_map.free(gpa, parsed2);
    try testing.expectEqualSlices(platform.Key, &.{.space}, parsed2.find("jump").?.keys);
}

test "input override: overrideSources is buildOverrideMap's inverse — every capture-produced source round-trips in its own vocabulary" {
    // The property the read-back seam rests on (#247): whatever the driver wrote, the
    // seam can hand back to the script *as the script spelled it*. A key stays bare, a
    // pad button gets its `pad_` prefix back — seed it in the wrong vocabulary and the
    // script's own comparisons against it silently stop matching.
    const gpa = testing.allocator;
    const proposed = [_]script.StrPair{
        .{ .key = "fire", .value = "d" },
        .{ .key = "pause", .value = "pad_south" },
        .{ .key = "up", .value = "pad_dpad_up" },
    };
    const map = try buildOverrideMap(gpa, &proposed);
    defer action_map.free(gpa, map);

    const back = try overrideSources(gpa, map);
    defer freeSources(gpa, back);

    try testing.expectEqual(proposed.len, back.len);
    for (back) |p| {
        for (proposed) |q| {
            if (std.mem.eql(u8, p.key, q.key)) {
                try testing.expectEqualStrings(q.value, p.value);
                break;
            }
        } else return error.TestUnexpectedResult;
    }
}

test "input override: overrideSources skips an entry no captured source could have produced, and keeps the rest" {
    // A hand-edited override (ADR 0041 §2 keeps the file human-editable) may hold shapes
    // the script's one-source-per-action field cannot express. Seeding what we can beats
    // refusing to seed at all — but the skip is real, so it is pinned, not implied.
    const gpa = testing.allocator;
    const map = try action_map.parse(gpa,
        \\.{ .actions = .{
        \\    .fire = .{ .type = .button, .keys = .{.d} },
        \\    .two_keys = .{ .type = .button, .keys = .{ .a, .s } },
        \\    .both_kinds = .{ .type = .button, .keys = .{.a}, .pad_buttons = .{.south} },
        \\    .move = .{ .type = .axis2d, .pad_stick = .left },
        \\} }
    );
    defer action_map.free(gpa, map);

    const back = try overrideSources(gpa, map);
    defer freeSources(gpa, back);

    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("fire", back[0].key);
    try testing.expectEqualStrings("d", back[0].value);
}

test "input override: a skipped entry is REPORTED, not silently dropped — the caller can name it" {
    // #247 was a SILENT loss; a narrower silent loss would be the same bug in miniature.
    // `seedBindings` reports every entry it could not hand the script, so the runner can
    // tell the player which hand-edited binding a rebind is about to drop.
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    const map = try action_map.parse(gpa,
        \\.{ .actions = .{
        \\    .fire = .{ .type = .button, .keys = .{.d} },
        \\    .two_keys = .{ .type = .button, .keys = .{ .a, .s } },
        \\} }
    );
    defer action_map.free(gpa, map);

    const fx = try CaptureFixture.init(gpa, accepting_handlers);
    defer fx.deinit(gpa);

    const seed = try seedBindings(gpa, &fx.rt, map);
    defer gpa.free(seed.skipped);
    try testing.expectEqual(@as(usize, 1), seed.seeded);
    try testing.expectEqual(@as(usize, 1), seed.skipped.len);
    try testing.expectEqualStrings("two_keys", seed.skipped[0]); // named, not just counted
}

test "input override: an empty override seeds an empty set, not a missing one" {
    const gpa = testing.allocator;
    const back = try overrideSources(gpa, .{});
    defer freeSources(gpa, back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "input override: SESSION 2 keeps session 1's rebind — seedBindings makes the whole-override write tell the truth (#247)" {
    // The bug this seam exists for, end to end and cross-session: two `OverrideWriter`
    // lifetimes against one file, with a fresh interpreter in between (a restart).
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // --- Session 1: rebind `jump`, persist, quit.
    {
        const fx = try CaptureFixture.init(gpa, accepting_handlers);
        defer fx.deinit(gpa);
        var writer: OverrideWriter = .init(&fx.rt);
        try fx.capture(gpa, "jump", "enter");
        try testing.expectEqual(Outcome{ .written = 1 }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    }

    // --- Session 2: a NEW interpreter — its `bindings` starts empty, exactly as a
    // restarted game's does. The seam is what tells it about session 1.
    const fx = try CaptureFixture.init(gpa, accepting_handlers);
    defer fx.deinit(gpa);

    const src = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const loaded = try action_map.parse(gpa, src);
    defer action_map.free(gpa, loaded);
    _ = try seedBindings(gpa, &fx.rt, loaded);

    // Seeding is not a proposal: the revision never moved, so a session that rebinds
    // nothing still writes nothing.
    var writer: OverrideWriter = .init(&fx.rt);
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));

    // Rebind a DIFFERENT action, and persist.
    try fx.capture(gpa, "fire", "pad_south");
    try testing.expectEqual(Outcome{ .written = 2 }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));

    // BOTH survive — before #247 this file listed `fire` alone.
    const src2 = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src2);
    const parsed = try action_map.parse(gpa, src2);
    defer action_map.free(gpa, parsed);
    try testing.expectEqual(@as(usize, 2), parsed.bindings.len);
    try testing.expectEqualSlices(platform.Key, &.{.enter}, parsed.find("jump").?.keys);
    try testing.expectEqualSlices(platform.GamepadButton, &.{.south}, parsed.find("fire").?.pad_buttons);
}

test "input override: seeding a package with no script, and a script that declares no bindings, is a clean no-op" {
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    const map = try buildOverrideMap(gpa, &.{.{ .key = "jump", .value = "enter" }});
    defer action_map.free(gpa, map);

    // No script at all (the default of every package that ships no Lua).
    var bare: script_runtime.Runtime = .{};
    defer bare.deinit(gpa);
    const bare_seed = try seedBindings(gpa, &bare, map);
    defer gpa.free(bare_seed.skipped);

    // A script with a handler table but no part in the bindings contract: it never reads
    // the seeded field and, with no revision field, never provokes a write.
    const fx = try CaptureFixture.init(gpa, "return { on_spawn = function() end }");
    defer fx.deinit(gpa);
    const seed = try seedBindings(gpa, &fx.rt, map);
    defer gpa.free(seed.skipped);
    var writer: OverrideWriter = .init(&fx.rt);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "input.zon", .{}));
}

test "input override: a script proposing nothing (no revision field) never writes — every package shipping today" {
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fx = try CaptureFixture.init(gpa, "return { on_spawn = function() end }");
    defer fx.deinit(gpa);

    var writer: OverrideWriter = .init(&fx.rt);
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "input.zon", .{}));
}

test "input override: a rejected proposal leaves the last-good file untouched and is reported once, not every poll" {
    if (!script.lua_enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fx = try CaptureFixture.init(gpa, accepting_handlers);
    defer fx.deinit(gpa);
    var writer: OverrideWriter = .init(&fx.rt);

    try fx.capture(gpa, "jump", "enter");
    try testing.expectEqual(Outcome{ .written = 1 }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    const good = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(good);

    // A source no `platform.Key`/`GamepadButton` knows — a script that accepted
    // something the engine cannot express as a binding.
    try fx.capture(gpa, "jump", "nosuchkey");
    try testing.expectEqual(Outcome{ .rejected = .unknown_source }, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));
    try testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, testing.io, tmp.dir, "input.zon", &fx.rt));

    const after = try tmp.dir.readFileAllocOptions(testing.io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(after);
    try testing.expectEqualStrings(good, after); // last-good contents intact
}
