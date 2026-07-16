//! ui_host — the **script-backed** `ui.Host` fill (issue #248; ADR 0034 §5, ADR 0041 §5).
//!
//! `ui` reads gameplay state one way, through the `Host` seam (ADR 0034 §5), and the
//! engine is what fills that seam. Until now the only fill was `render_ui.worldHost`,
//! which resolves a bound name to a **numeric data component** on the live `World`
//! (ADR 0024). That leaves a whole class of displayable state unreachable: a fact the
//! *script* owns and the engine only ever reads back — the player's current input
//! binding being the concrete case (ADR 0041 §4's `bindings` handler field, the same
//! seam the persistence driver reads through `handlerFieldStrMap`). A screen that
//! cannot read it does not merely omit it: `games/menu`'s controls rows showed the
//! shipped default as static text, so after a rebind the row actively lied.
//!
//! `ScriptHost` closes that, generically: a widget whose `bind` has the form
//! **`field.key`** resolves to the string at `key` in the *table-valued handler field*
//! `field`. That dot convention, and the chaining rule below, are pinned by **ADR 0034
//! §5's #248 amendment** — `bind` is content-facing ZON, so a `.` is now reserved for
//! every installed host, not just this one. It is engine-side glue that names no field,
//! no key, and no screen (invariant
//! #6: the vocabulary comes from the game's ZON `bind`, never from `src/`). Anything
//! else — a bare name, an unknown field, a key the script's table does not hold —
//! falls through to `next` (chain `render_ui.worldHost` in, so ONE installed host
//! serves both a HUD's numeric `score` and a controls row's live binding), and if that
//! resolves nothing either, `ui.boundValue` falls back to the widget's static `text`.
//! An unrebound action therefore keeps showing the default its ZON authored — correct
//! by construction, because that IS the effective binding.
//!
//! Read-only and additive: it queries the script through the existing engine→state
//! reads (`Runtime.handlerFieldStrMap`, #250's precedent), adds no `mana` member, and
//! so leaves ADR 0003 §5's version gate untouched. **Cosmetic and hash-excluded**
//! (ADR 0034 §4): like every `Host` fill it writes nothing, so it cannot perturb
//! `World.stateHash`. Under a default (no-Lua) build `Runtime` is the inert
//! `NoopRuntime` whose `handlerFieldStrMap` is always null, so every bind falls
//! through to `next` and a screen renders its static text.

const std = @import("std");
const ui = @import("ui");
const script = @import("script");
const script_runtime = @import("script_runtime.zig");

const Allocator = std.mem.Allocator;
const Runtime = script_runtime.Runtime;

/// A `ui.Host` over the loaded script's handler table: `bind = "field.key"` reads the
/// string at `key` of table-valued handler `field`; every other name delegates to
/// `next`.
///
/// **Lifetime**: each resolve copies out of Lua and the copy is retained until
/// `deinit`, so a returned `.text` outlives the `Host.value` call that produced it (the
/// seam's contract) — and nothing is cached, so two resolves in one frame both see live
/// script state. That makes it a **short-lived, query-batch-scoped** value: build one,
/// project/read a screen through it, `deinit`. The intended `gpa` is a per-frame arena
/// (invariant #3: the render path's per-frame allocations are arena bumps, not mallocs).
/// `rt` and whatever backs `next` are borrowed and must outlive it.
pub const ScriptHost = struct {
    gpa: Allocator,
    rt: *Runtime,
    /// The host a name this one does not resolve is passed to (typically
    /// `render_ui.worldHost`), or null to resolve only script fields.
    next: ?ui.Host,
    /// Every `handlerFieldStrMap` result handed out of `value`, owned until `deinit`.
    reads: std.ArrayList([]const script.StrPair) = .empty,
    /// Set when a resolve hit `error.OutOfMemory` — `Host.value` cannot fail, so the
    /// failure is latched here for the caller to surface (see `oomed`).
    oom: bool = false,

    /// Build a host reading `rt`'s handler table, delegating unresolved names to `next`.
    /// Nothing is allocated until a name resolves. `gpa` owns the resolved copies.
    pub fn init(gpa: Allocator, rt: *Runtime, next: ?ui.Host) ScriptHost {
        return .{ .gpa = gpa, .rt = rt, .next = next };
    }

    /// Free every copy this host read out of the script. Invalidates all `.text` values
    /// it returned.
    pub fn deinit(self: *ScriptHost) void {
        for (self.reads.items) |pairs| Runtime.freeStrMap(self.gpa, pairs);
        self.reads.deinit(self.gpa);
        self.* = undefined;
    }

    /// The `ui.Host` view of this struct — borrows it, so it must outlive the host.
    pub fn host(self: *ScriptHost) ui.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// True once a resolve ran out of memory. `Host.value` returns `?Value` and cannot
    /// error, so a caller that must not silently show stale/static text (the render
    /// path) checks this after a batch and propagates `error.OutOfMemory`.
    pub fn oomed(self: *const ScriptHost) bool {
        return self.oom;
    }

    const vtable: ui.Host.VTable = .{ .value = value };

    /// The vtable read: `field.key` → the script's `field[key]`, else `next`. Splits on
    /// the FIRST `.`, so a key may itself contain dots; an empty field or key is not a
    /// path and delegates.
    fn value(ctx: *anyopaque, name: []const u8) ?ui.Value {
        const self: *ScriptHost = @ptrCast(@alignCast(ctx));
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return self.fallback(name);
        const field = name[0..dot];
        const key = name[dot + 1 ..];
        if (field.len == 0 or key.len == 0) return self.fallback(name);
        const found = self.lookup(field, key) catch {
            self.oom = true;
            return null; // an OOM must not be reported as "the script says nothing"
        };
        return if (found) |text| .{ .text = text } else self.fallback(name);
    }

    /// The string at `key` of table-valued handler field `field`, or null when the
    /// script declares no such field/key (or no script is loaded at all). The result is
    /// owned by `self` until `deinit`. Errors: `error.OutOfMemory`.
    fn lookup(self: *ScriptHost, field: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
        // `handlerFieldStrMap` names its field with a Lua-side sentinel-terminated key.
        const field_z = try self.gpa.dupeZ(u8, field);
        defer self.gpa.free(field_z);
        const pairs = try self.rt.handlerFieldStrMap(self.gpa, field_z) orelse return null;
        errdefer Runtime.freeStrMap(self.gpa, pairs);
        // Retained rather than freed here: the `.text` handed back must outlive the call.
        try self.reads.append(self.gpa, pairs);
        for (pairs) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// Pass `name` to the chained host, or null when there is none.
    fn fallback(self: *ScriptHost, name: []const u8) ?ui.Value {
        const next = self.next orelse return null;
        return next.value(name);
    }
};

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

/// A stand-in for the numeric `render_ui.worldHost` a real chain ends in — `ui_host`
/// may not import `World` glue, so the chain is exercised against a plain double.
const NumberHost = struct {
    score: f64 = 0,

    fn value(ctx: *anyopaque, name: []const u8) ?ui.Value {
        const self: *NumberHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "score")) return .{ .number = self.score };
        return null;
    }
    const vtable: ui.Host.VTable = .{ .value = value };

    fn host(self: *NumberHost) ui.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "ui_host: a bare name and an unresolved path delegate to the chained host" {
    // True on EVERY build (no Lua needed): the chain rule is what keeps a HUD's numeric
    // `score` working once a script host is installed in front of `worldHost`.
    const gpa = testing.allocator;
    var rt: Runtime = .{};
    defer rt.deinit(gpa);
    var numbers: NumberHost = .{ .score = 1200 };

    var sh: ScriptHost = .init(gpa, &rt, numbers.host());
    defer sh.deinit();
    const h = sh.host();

    // A bare name is not a handler-field path: it goes straight to the chained host.
    try testing.expectEqual(@as(f64, 1200), h.value("score").?.number);
    // A malformed path (empty field / empty key) is not one either.
    try testing.expect(h.value(".fire") == null);
    try testing.expect(h.value("bindings.") == null);
    // A name nothing in the chain resolves yields null, so `boundValue` falls back to
    // the widget's static text.
    const w: ui.Widget = .{ .kind = .label, .bind = "bindings.fire", .text = "W" };
    try testing.expectEqualStrings("W", ui.boundValue(&w, h).text);
    try testing.expect(!sh.oomed());
}

test "ui_host: no chained host resolves nothing but the script's own fields" {
    const gpa = testing.allocator;
    var rt: Runtime = .{};
    defer rt.deinit(gpa);
    var sh: ScriptHost = .init(gpa, &rt, null);
    defer sh.deinit();
    try testing.expect(sh.host().value("score") == null);
}

test "ui_host: a bound label reads a live string off the script's handler table (-Denable-lua)" {
    if (script.api_version == 0) return error.SkipZigTest; // no handler table
    const gpa = testing.allocator;
    var rt: Runtime = .{};
    defer rt.deinit(gpa);
    // A handler table shaped exactly like ADR 0041 §4's: a table-valued field of
    // string→string entries, one per rebound action.
    try rt.loadHandlers(gpa, "return { bindings = { fire = \"d\" }, score = 5 }");

    var sh: ScriptHost = .init(gpa, &rt, null);
    defer sh.deinit();
    const h = sh.host();

    // The path resolves to the LIVE string, so a label bound to it stops showing its
    // static default.
    const fire: ui.Widget = .{ .kind = .label, .bind = "bindings.fire", .text = "W" };
    try testing.expectEqualStrings("d", ui.boundValue(&fire, h).text);
    // A key the table does not hold ⇒ the widget's static text: an action the player
    // never rebound keeps displaying the default its ZON authored.
    const pause: ui.Widget = .{ .kind = .label, .bind = "bindings.pause", .text = "S" };
    try testing.expectEqualStrings("S", ui.boundValue(&pause, h).text);
    // A field that is not a table of strings is not a path target either.
    try testing.expect(h.value("score.fire") == null);
    // An absent field likewise.
    try testing.expect(h.value("nope.fire") == null);
}

test "ui_host: a resolve reflects a later mutation — nothing is cached (-Denable-lua)" {
    // The staleness guard: a host is a per-frame value, and two frames must not share a
    // snapshot. Without this, a rebind would leave the row lying until the next reload —
    // the exact bug (#248) this module exists to fix.
    if (script.api_version == 0) return error.SkipZigTest;
    const gpa = testing.allocator;
    var rt: Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, "return { bindings = {} }");

    var sh: ScriptHost = .init(gpa, &rt, null);
    defer sh.deinit();
    const h = sh.host();
    try testing.expect(h.value("bindings.fire") == null);

    // The engine's own write twin stands in for an accepted capture.
    rt.setHandlerFieldStrMap("bindings", &.{.{ .key = "fire", .value = "d" }});
    try testing.expectEqualStrings("d", h.value("bindings.fire").?.text);

    // Both resolves' strings are still valid (owned until `deinit`), not just the last.
    try testing.expectEqualStrings("d", h.value("bindings.fire").?.text);
}
