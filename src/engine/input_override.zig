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
//! Marginally over the ~500-line soft limit (~240 lines of driver, the rest tests):
//! the driver itself is small, and splitting its tests — the `pad_`-prefix translation,
//! the write/parse round trip, and the live-interpreter `OverrideWriter` staircase —
//! away from the ~240 lines they pin would only scatter one small concern across two
//! files. Revisit if the driver itself grows (e.g. when #240 moves the override path).

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
    /// The `revision_field` value the current override file reflects. Seeded from the
    /// script at `init` rather than 0 so a package whose script *loads* the existing
    /// override into its handler table (the expected shape — the file it read is
    /// already on disk) does not provoke a pointless rewrite on the first poll.
    last_revision: i64,

    /// Seed from `rt`'s current revision: whatever the script starts with is treated as
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
