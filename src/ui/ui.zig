//! ui — the data-driven game-UI subsystem (ADR 0034; issue #132, Phase 1 spine).
//!
//! A game screen (HUD, menu, panel) is a **declarative widget tree authored in ZON**
//! and interpreted here: `parse` turns the ZON into `Screen`/`Widget` structs, `layout`
//! computes each widget's screen `Rect` from a viewport (basic flex + anchor layout),
//! and `hitTest` maps a point back to the widget under it. A widget may **bind** to a
//! named gameplay scalar/string read one-way through the `Host` seam (ADR 0015 pattern)
//! — the engine fills that seam from live sim/ECS state, so the UI displays gameplay
//! data without ever becoming a second source of truth for it.
//!
//! **Tier (ADR 0034 §5): `ui → core + gpu + platform`.** It imports no `ecs`/`data`
//! (a `ui → ecs` edge is a build error, by design) and names no Vulkan type — it draws
//! through the `gpu` port and receives input through `platform` in later slices, and
//! reaches gameplay state only through `Host`. **Cosmetic and hash-excluded** (ADR 0034
//! §4): nothing here ever enters `World.stateHash`; layout is pure geometry over plain
//! floats, so it is fully headless-testable against the null backend, no window.
//!
//! Also here (issue #134, hit-test/focus half): a widget may be marked `focusable`;
//! `focusOrder` walks the laid-out tree into the deterministic keyboard/gamepad focus
//! order, `Focus` tracks and moves the focused widget (`next`/`prev`/directional
//! `move`/pointer-driven `focusAt`), and `consumesPointer` says whether a click lands
//! on the UI at all — so a caller can route input to the UI **before** gameplay input
//! sees it, without gameplay ever touching `ui` internals. Event *dispatch* to Lua
//! (`on_click`/`on_focus`/`on_activate`, ADR 0039, now accepted) lives one tier up in
//! `src/engine/ui_dispatch.zig`, which consumes these primitives — `ui` itself stays the
//! pure interpreter and names no Lua/handle type. What `ui` contributes to that surface
//! is the content-authored `Widget.id` (ADR 0039 §2), the stable name a script's UI-event
//! handler correlates against.
//!
//! Deferred to later phased slices (ADR 0034 §8): GPU draw-list emission and text/glyph
//! metrics (#131/#133, done), event dispatch to Lua (#134, wired in `engine/ui_dispatch`
//! per ADR 0039), styling/theming. This slice is the pure interpreter: parse + layout rects +
//! hit-test + focus nav + a one-way binding read, all allocator-explicit and free of
//! hidden global state (hot-reload friendly — re-`parse` a file into a fresh `Screen`).
//!
//! Split per issue #151 (this file was 807 lines): the parse/layout/hit-test core lives
//! in sibling `types.zig`, and focus navigation (`Focus`/`NavDirection`/`navDirection`/
//! `isActivateKey`) in sibling `focus.zig` — the clean seam the maintainer's follow-up
//! comment on #151 identified (shared leaf types `Rect`/`Widget`/`Placed`/`hitTest` in
//! one file both `focus.zig` and this file import, so neither needs a back-`@import`).
//! Both are re-exported below so the public API (`ui.Widget`, `ui.layout`, `ui.Focus`,
//! …) is unchanged. This file keeps only what doesn't fit either sibling: the `Host`
//! seam and `boundValue`, which read binding *values*, not widget geometry or focus.

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const platform = @import("platform");

const types = @import("types.zig");
const focus = @import("focus.zig");

// Re-exported so the public API (`ui.Widget`, `ui.layout`, `ui.hitTest`, …) is
// unchanged by the split — see the file-top doc comment.
pub const Kind = types.Kind;
pub const Layout = types.Layout;
pub const Direction = types.Direction;
pub const Anchor = types.Anchor;
pub const Rect = types.Rect;
pub const Value = types.Value;
pub const Widget = types.Widget;
pub const Screen = types.Screen;
pub const parse = types.parse;
pub const free = types.free;
pub const Placed = types.Placed;
pub const layout = types.layout;
pub const hitTest = types.hitTest;
pub const consumesPointer = types.consumesPointer;
pub const focusOrder = types.focusOrder;

pub const NavDirection = focus.NavDirection;
pub const navDirection = focus.navDirection;
pub const isActivateKey = focus.isActivateKey;
pub const Focus = focus.Focus;

/// The abstract host seam (ADR 0015 pattern, ADR 0034 §5): the one-way view of live
/// gameplay state a bound widget reads through. `ui` names no `World`/`ecs.Entity`;
/// `engine` fills this vtable from the live `Sim` for the duration of a UI update, and
/// a fake host over plain data exercises binding headlessly (the §5 test seam).
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Function-pointer table over `core`/builtin types only — nothing engine- or
    /// `ecs`-specific crosses the seam. Grows additively; a surface change is its own
    /// ADR (ADR 0034 §5, mirroring ADR 0003 §5).
    pub const VTable = struct {
        /// The current value of bound name `name`, or `null` if the host exposes no
        /// such binding (the widget then shows its static `text`). `name` is borrowed
        /// for the call only. A returned `.text` slice must outlive the call's use.
        value: *const fn (ctx: *anyopaque, name: []const u8) ?Value,
    };

    /// Read bound `name` through the vtable (thin forwarder).
    pub fn value(self: Host, name: []const u8) ?Value {
        return self.vtable.value(self.ctx, name);
    }
};

/// The value a widget displays: its `bind`ing read through `host` when the binding is
/// set and the host resolves it, else its static `text`. This is the one-way binding
/// read (ADR 0034 §4) — the seam a HUD label uses to show live `score`/`lives` without
/// `ui` touching `World`. Pure; passing `null` for `host` always yields the static text.
pub fn boundValue(w: *const Widget, host: ?Host) Value {
    if (w.bind.len > 0) {
        if (host) |h| {
            if (h.value(w.bind)) |v| return v;
        }
    }
    return .{ .text = w.text };
}

/// Marker asserting the module DAG (`ui → core + gpu + platform`, ADR 0034 §5) is
/// assembled: referencing each port's own `ready` makes the tier a compile-enforced
/// fact, exactly as the other port modules do.
pub const ready = core.ready and gpu.ready and platform.ready;

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "ui: module is wired into the DAG (core + gpu + platform)" {
    try testing.expect(ready);
}

/// A fake `Host` over a fixed name→value table — the headless binding double (ADR
/// 0034 §5), standing in for the engine's live-`Sim` fill.
const FakeHost = struct {
    score: f64,
    label: []const u8,

    fn value(ctx: *anyopaque, name: []const u8) ?Value {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "score")) return .{ .number = self.score };
        if (std.mem.eql(u8, name, "title")) return .{ .text = self.label };
        return null;
    }
    const vtable: Host.VTable = .{ .value = value };
};

test "ui: boundValue reads a bound scalar through the host, else falls back to text" {
    var fake: FakeHost = .{ .score = 1200, .label = "PLAY" };
    const host: Host = .{ .ctx = &fake, .vtable = &FakeHost.vtable };

    // A numeric binding resolves through the host.
    const score_w: Widget = .{ .kind = .label, .bind = "score", .text = "0" };
    try testing.expectEqual(@as(f64, 1200), boundValue(&score_w, host).number);

    // A text binding resolves too.
    const title_w: Widget = .{ .kind = .label, .bind = "title", .text = "?" };
    try testing.expectEqualStrings("PLAY", boundValue(&title_w, host).text);

    // An unknown binding falls back to the widget's static text.
    const missing_w: Widget = .{ .kind = .label, .bind = "nope", .text = "static" };
    try testing.expectEqualStrings("static", boundValue(&missing_w, host).text);

    // No binding at all ⇒ static text, even with a host present.
    const plain_w: Widget = .{ .kind = .label, .text = "plain" };
    try testing.expectEqualStrings("plain", boundValue(&plain_w, host).text);

    // No host ⇒ static text even for a bound widget (degrades gracefully).
    try testing.expectEqualStrings("0", boundValue(&score_w, null).text);
}
