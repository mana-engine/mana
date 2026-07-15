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
//! File-length note (CLAUDE.md soft ~500-line guideline): this file is over it. The
//! focus/hit-test additions (issue #134) need `Rect`/`Widget`/`Placed`/`hitTest`, all
//! defined above in this same file; splitting them into a sibling file would need that
//! file to import `ui.zig` back (a same-module mutual `@import`, legal in Zig but an
//! avoidable complication for a first slice) purely to dodge the soft limit. Kept as one
//! file for now; a follow-on can split `focus.zig` out if the module keeps growing.

const std = @import("std");
const core = @import("core");
const gpu = @import("gpu");
const platform = @import("platform");

const Allocator = std.mem.Allocator;

/// The kind of a widget — a small, genre-neutral vocabulary (invariant #6: no genre
/// concept leaks into `src/`). Content decides what a `panel` or `label` *means*.
pub const Kind = enum {
    /// A layout-only grouping box; draws nothing itself, arranges its children.
    container,
    /// A filled rectangle (background/frame), `color`-tinted.
    panel,
    /// A text run: static `text`, or the value of a `bind`ing when set.
    label,
    /// An image reference (`image`); the atlas/sheet resolution is a render-side slice.
    image,
};

/// How a container arranges its children (ADR 0034 §2 "basic flex/anchor layout").
pub const Layout = enum {
    /// Lay children out sequentially along `direction`, separated by `gap`; a child
    /// with no size on the main axis flexes to share the leftover space equally.
    flex,
    /// Position each child independently by its own `anchor` within the content rect
    /// (the natural HUD shape: score anchored top-left, lives top-right).
    anchor,
};

/// The main axis a `flex` container lays its children along.
pub const Direction = enum { row, column };

/// Where a sized box sits within its available rect (a 3×3 grid). A widget with no
/// explicit `width`/`height` ignores its anchor and fills the rect instead.
pub const Anchor = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    /// Horizontal placement of a box of width `size` in `[origin, origin+extent)`.
    fn placeX(self: Anchor, origin: f32, extent: f32, size: f32) f32 {
        return switch (self) {
            .top_left, .center_left, .bottom_left => origin,
            .top_center, .center, .bottom_center => origin + (extent - size) / 2,
            .top_right, .center_right, .bottom_right => origin + (extent - size),
        };
    }

    /// Vertical placement of a box of height `size` in `[origin, origin+extent)`.
    fn placeY(self: Anchor, origin: f32, extent: f32, size: f32) f32 {
        return switch (self) {
            .top_left, .top_center, .top_right => origin,
            .center_left, .center, .center_right => origin + (extent - size) / 2,
            .bottom_left, .bottom_center, .bottom_right => origin + (extent - size),
        };
    }
};

/// An axis-aligned rectangle in screen pixels (origin top-left, +y down) — the layout
/// output and the viewport input. Plain data; no GPU/NDC vocabulary (that conversion is
/// a render-side slice, ADR 0034 §8).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    /// True iff point (`px`, `py`) lies within the rect — right/bottom edges exclusive
    /// so abutting rects never both claim a boundary point (deterministic hit-testing).
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

/// A displayed scalar or string a widget binds to (ADR 0034 §4). The binding is
/// **one-way** (sim/ECS state → widget); the UI never writes gameplay state through it.
pub const Value = union(enum) {
    number: f64,
    text: []const u8,
};

/// One node of a UI screen as authored in ZON. Every field has a default so a minimal
/// widget (`.{ .kind = .label, .text = "Score" }`) parses; new fields stay additive.
/// Sizes and gaps are in screen pixels. A `container` uses `layout`/`direction`/`gap`/
/// `padding`; leaf kinds ignore them.
pub const Widget = struct {
    kind: Kind = .container,
    /// Container arrangement mode (ignored by leaf kinds).
    layout: Layout = .flex,
    /// Main axis for a `flex` container.
    direction: Direction = .column,
    /// Placement within the available rect when this widget has an explicit size; a
    /// widget with neither `width` nor `height` fills the rect and ignores this.
    anchor: Anchor = .top_left,
    /// Explicit width in pixels; `null` ⇒ fill / flex on the horizontal axis.
    width: ?f32 = null,
    /// Explicit height in pixels; `null` ⇒ fill / flex on the vertical axis.
    height: ?f32 = null,
    /// Inner inset (px) applied on all sides before laying children out.
    padding: f32 = 0,
    /// Spacing (px) between consecutive `flex` children.
    gap: f32 = 0,
    /// Static display text for a `label` (used when `bind` is empty or unresolved).
    text: []const u8 = "",
    /// Name of a bound gameplay value read one-way through the `Host` (e.g. "score").
    /// Empty ⇒ the widget is not bound. See `boundValue`.
    bind: []const u8 = "",
    /// Content-authored stable name a script correlates a UI event to (ADR 0039 §2):
    /// `on_click`/`on_focus`/`on_activate` carry it as `ev.id`, so a handler can tell
    /// *which* widget fired (`if ev.id == "start_button" then …`) without walking the
    /// tree. Empty (`""`) ⇒ anonymous: the widget still gets a handle and still fires
    /// events, it is simply not addressable by name — the same empty-string-sentinel
    /// convention `bind`/`text` use. Purely a content label; never hashed (ADR 0034 §4).
    id: []const u8 = "",
    /// Image reference for an `image` widget (resolved render-side, deferred slice).
    image: []const u8 = "",
    /// RGBA tint for `panel`/`label`, 0..1. Cosmetic; never hashed.
    color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Child widgets, laid out per this widget's `layout`. Empty for a leaf.
    children: []const Widget = &.{},
    /// Whether this widget participates in keyboard/gamepad focus navigation (ADR 0034
    /// §8, issue #134). A container is typically not focusable itself; its focusable
    /// descendants (a button, a field) are. Focus *state* built over this (which widget
    /// currently has focus) is cosmetic-adjacent and never hashed, like layout (ADR 0034
    /// §4) — only the event *effects* a handler applies would be.
    focusable: bool = false,
};

/// A parsed UI screen: a name plus its `root` widget. The unit `parse` returns and
/// `layout`/`hitTest` operate on. Owns its heap allocations (strings, child slices);
/// free with `free`.
pub const Screen = struct {
    name: []const u8 = "",
    root: Widget,
};

/// Parse a `Screen` from NUL-terminated ZON `source` (mirrors `scene.parse`). The
/// result owns heap allocations; free with `free`. Pure: source in, data out — the
/// hot-reload entry point (re-parse a file into a fresh `Screen`, no global state).
/// Errors: `error.OutOfMemory`, `error.ParseZon` (malformed content — the caller keeps
/// the last-good screen, ADR 0005).
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!Screen {
    return std.zon.parse.fromSliceAlloc(Screen, gpa, source, null, .{});
}

/// Free a `Screen` returned by `parse`.
pub fn free(gpa: Allocator, screen: Screen) void {
    std.zon.parse.free(gpa, screen);
}

/// A widget together with the screen `Rect` `layout` computed for it. `widget` borrows
/// the `Screen` the layout was computed from (valid until that `Screen` is freed).
pub const Placed = struct {
    widget: *const Widget,
    rect: Rect,
};

/// Compute the screen rect of every widget in `screen`, given the `viewport` rect the
/// root fills. Returns the widgets in **pre-order** (parent before its children) — the
/// order a painter draws them, so `hitTest` scanning it in reverse yields the topmost.
/// Pure geometry over plain floats: no window, no GPU, deterministic — the headless
/// acceptance bar (ADR 0034 §2). Caller owns the returned slice (`gpa.free`). Errors:
/// `error.OutOfMemory`.
pub fn layout(gpa: Allocator, screen: *const Screen, viewport: Rect) Allocator.Error![]Placed {
    var out: std.ArrayList(Placed) = .empty;
    errdefer out.deinit(gpa);
    try placeWidget(gpa, &screen.root, viewport, &out);
    return out.toOwnedSlice(gpa);
}

/// Place `w` within its available rect `avail`, append it, then recurse into children
/// per its `layout`. A widget with an explicit size is anchored within `avail`; one
/// without fills `avail`.
fn placeWidget(gpa: Allocator, w: *const Widget, avail: Rect, out: *std.ArrayList(Placed)) Allocator.Error!void {
    const rect = resolveRect(w, avail);
    try out.append(gpa, .{ .widget = w, .rect = rect });
    if (w.children.len == 0) return;

    // Content box: the rect inset by padding on all sides (never negative).
    const content: Rect = .{
        .x = rect.x + w.padding,
        .y = rect.y + w.padding,
        .w = @max(0, rect.w - 2 * w.padding),
        .h = @max(0, rect.h - 2 * w.padding),
    };
    switch (w.layout) {
        .anchor => for (w.children) |*c| try placeWidget(gpa, c, content, out),
        .flex => try placeFlex(gpa, w, content, out),
    }
}

/// Anchor a box the size of `w`'s explicit dimensions (a missing dimension fills that
/// axis) within `avail`, clamped so it never exceeds `avail`.
fn resolveRect(w: *const Widget, avail: Rect) Rect {
    const rw = @min(w.width orelse avail.w, avail.w);
    const rh = @min(w.height orelse avail.h, avail.h);
    return .{
        .x = w.anchor.placeX(avail.x, avail.w, rw),
        .y = w.anchor.placeY(avail.y, avail.h, rh),
        .w = rw,
        .h = rh,
    };
}

/// Lay `w`'s children out sequentially along `w.direction` within `content`: each child
/// takes its explicit main-axis size, and children with no main-axis size share the
/// leftover space equally (the flex rule). Cross axis spans the full content extent
/// (the child may anchor a smaller box within its slot via `resolveRect`).
fn placeFlex(gpa: Allocator, w: *const Widget, content: Rect, out: *std.ArrayList(Placed)) Allocator.Error!void {
    const n = w.children.len;
    const row = w.direction == .row;
    const total_gap = if (n > 0) w.gap * @as(f32, @floatFromInt(n - 1)) else 0;
    const main_avail = (if (row) content.w else content.h) - total_gap;

    // Pass 1: sum the explicit main sizes and count the flexible (unsized) children.
    var used: f32 = 0;
    var flex_count: usize = 0;
    for (w.children) |*c| {
        if (mainSize(c, row)) |m| used += m else flex_count += 1;
    }
    const each = if (flex_count > 0) @max(0, main_avail - used) / @as(f32, @floatFromInt(flex_count)) else 0;

    // Pass 2: place each child in its slot, advancing the cursor by size + gap.
    var cursor = if (row) content.x else content.y;
    for (w.children) |*c| {
        const main = mainSize(c, row) orelse each;
        const slot: Rect = if (row)
            .{ .x = cursor, .y = content.y, .w = main, .h = content.h }
        else
            .{ .x = content.x, .y = cursor, .w = content.w, .h = main };
        try placeWidget(gpa, c, slot, out);
        cursor += main + w.gap;
    }
}

/// A widget's explicit size on the flex main axis (`width` for a row, `height` for a
/// column), or `null` when it should flex.
fn mainSize(w: *const Widget, row: bool) ?f32 {
    return if (row) w.width else w.height;
}

/// The topmost widget under screen point (`px`, `py`), or `null` if none contains it.
/// Scans `placed` (a `layout` result, in paint order) in reverse so the last-painted —
/// the deepest/frontmost widget — wins, the intuitive hit-testing result. Pure; the
/// returned pointer borrows the `Screen` the layout came from.
pub fn hitTest(placed: []const Placed, px: f32, py: f32) ?*const Widget {
    var i = placed.len;
    while (i > 0) {
        i -= 1;
        if (placed[i].rect.contains(px, py)) return placed[i].widget;
    }
    return null;
}

/// True iff pointer input at (`px`, `py`) should be **consumed by the UI** rather than
/// falling through to gameplay input (ADR 0034 §4/§8, issue #134: "UI consumes input
/// before gameplay input"). The screen is modal over whatever it covers: any widget
/// under the point — focusable or not (a background panel still blocks a click) —
/// claims it. Pure; the caller checks this before routing the same point to gameplay.
pub fn consumesPointer(placed: []const Placed, px: f32, py: f32) bool {
    return hitTest(placed, px, py) != null;
}

/// The subset of `placed` whose widget is `focusable`, in the same pre-order (paint)
/// sequence `layout` produced — the deterministic **focus order** `Focus.next`/`.prev`
/// walk (ADR 0034 §8, issue #134). Caller owns the returned slice (`gpa.free`). Errors:
/// `error.OutOfMemory`.
pub fn focusOrder(gpa: Allocator, placed: []const Placed) Allocator.Error![]const Placed {
    var out: std.ArrayList(Placed) = .empty;
    errdefer out.deinit(gpa);
    for (placed) |p| if (p.widget.focusable) try out.append(gpa, p);
    return out.toOwnedSlice(gpa);
}

/// A screen-space direction for directional focus navigation (ADR 0034 §8, issue #134).
/// Named distinctly from `Direction` (a `flex` container's main axis) — this is about
/// *where on screen* focus moves, not how children are laid out.
pub const NavDirection = enum { up, down, left, right };

/// Map an arrow key to the `NavDirection` it drives, or `null` for a key that isn't one
/// (issue #134: focus nav rides the same arrow keys a mover already reads — `platform`
/// has no separate gamepad key set yet, ADR 0009, so there is nothing else to map).
pub fn navDirection(key: platform.Key) ?NavDirection {
    return switch (key) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        else => null,
    };
}

/// Whether `key` activates the currently focused widget (issue #134's `on_activate`
/// trigger: enter or space, mirroring the common "confirm" convention). A pure
/// key-name predicate — pairing it with `Focus.current` to actually fire an event is
/// the caller's job (deferred: see `src/ui/README.md`).
pub fn isActivateKey(key: platform.Key) bool {
    return key == .enter or key == .space;
}

/// The center point of `r`, used by directional focus navigation to rank candidates.
fn center(r: Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

/// Tracks which focusable widget currently holds input focus, by identity (a pointer
/// into the `Screen` the layout was computed from). `null` means nothing is focused —
/// the initial state, or after a hot-reload rebuilt the tree (the caller re-resolves;
/// `ui` holds no cross-`Screen` identity). Cosmetic-adjacent, never hashed (ADR 0034 §4).
pub const Focus = struct {
    current: ?*const Widget = null,

    /// Move focus to the next entry in `order` after `current` (wrapping to the first);
    /// if nothing is focused, focuses the first entry. Returns `false` (no-op) iff
    /// `order` is empty.
    pub fn next(self: *Focus, order: []const Placed) bool {
        return self.step(order, 1);
    }

    /// Move focus to the entry in `order` before `current` (wrapping to the last); if
    /// nothing is focused, focuses the last entry. Returns `false` (no-op) iff `order`
    /// is empty.
    pub fn prev(self: *Focus, order: []const Placed) bool {
        return self.step(order, -1);
    }

    fn step(self: *Focus, order: []const Placed, delta: isize) bool {
        if (order.len == 0) return false;
        const n: isize = @intCast(order.len);
        const idx: isize = if (self.indexOf(order)) |i| @intCast(i) else if (delta > 0) -1 else 0;
        const new: isize = @mod(idx + delta, n);
        self.current = order[@intCast(new)].widget;
        return true;
    }

    fn indexOf(self: Focus, order: []const Placed) ?usize {
        const cur = self.current orelse return null;
        for (order, 0..) |p, i| if (p.widget == cur) return i;
        return null;
    }

    /// Move focus toward the nearest widget in `order` that lies in screen-space
    /// direction `dir` from the currently focused widget (issue #134 directional nav):
    /// candidates on the wrong side of `current` on that axis are excluded; the closest
    /// one along the primary axis wins, ties broken by cross-axis distance. If nothing
    /// is currently focused, focuses the first entry instead (same bootstrap rule as
    /// `next`). Returns `false` (no-op, focus unchanged) if no candidate qualifies.
    pub fn move(self: *Focus, order: []const Placed, dir: NavDirection) bool {
        if (order.len == 0) return false;
        const cur = self.current orelse {
            self.current = order[0].widget;
            return true;
        };
        var from: ?Rect = null;
        for (order) |p| if (p.widget == cur) {
            from = p.rect;
            break;
        };
        const fc = center(from orelse {
            self.current = order[0].widget;
            return true;
        });

        var best: ?*const Widget = null;
        var best_primary: f32 = std.math.inf(f32);
        var best_secondary: f32 = std.math.inf(f32);
        for (order) |p| {
            if (p.widget == cur) continue;
            const c = center(p.rect);
            const dx = c[0] - fc[0];
            const dy = c[1] - fc[1];
            var primary: f32 = undefined;
            var secondary: f32 = undefined;
            switch (dir) {
                .up => {
                    if (dy >= 0) continue;
                    primary = -dy;
                    secondary = @abs(dx);
                },
                .down => {
                    if (dy <= 0) continue;
                    primary = dy;
                    secondary = @abs(dx);
                },
                .left => {
                    if (dx >= 0) continue;
                    primary = -dx;
                    secondary = @abs(dy);
                },
                .right => {
                    if (dx <= 0) continue;
                    primary = dx;
                    secondary = @abs(dy);
                },
            }
            if (primary < best_primary or (primary == best_primary and secondary < best_secondary)) {
                best_primary = primary;
                best_secondary = secondary;
                best = p.widget;
            }
        }
        if (best) |b| {
            self.current = b;
            return true;
        }
        return false;
    }

    /// Hit-test `placed` at (`px`, `py`) and, if the topmost widget there is
    /// `focusable`, focus it and return it (issue #134: a pointer click on a focusable
    /// widget drives focus onto it, same as the entry point to `on_focus`). Returns
    /// `null` and leaves focus unchanged if the point hits nothing, or hits a
    /// non-focusable widget.
    pub fn focusAt(self: *Focus, placed: []const Placed, px: f32, py: f32) ?*const Widget {
        const hit = hitTest(placed, px, py) orelse return null;
        if (!hit.focusable) return null;
        self.current = hit;
        return hit;
    }
};

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

test "ui: parse round-trips a nested widget tree with defaults" {
    const src =
        \\.{
        \\    .name = "hud",
        \\    .root = .{
        \\        .kind = .container,
        \\        .layout = .anchor,
        \\        .padding = 8,
        \\        .children = .{
        \\            .{ .kind = .label, .anchor = .top_left, .width = 100, .height = 20, .bind = "score", .text = "0" },
        \\            .{ .kind = .label, .anchor = .top_right, .width = 100, .height = 20, .bind = "lives", .text = "3" },
        \\        },
        \\    },
        \\}
    ;
    const screen = try parse(testing.allocator, src);
    defer free(testing.allocator, screen);

    try testing.expectEqualStrings("hud", screen.name);
    try testing.expectEqual(Kind.container, screen.root.kind);
    try testing.expectEqual(Layout.anchor, screen.root.layout);
    try testing.expectEqual(@as(f32, 8), screen.root.padding);
    try testing.expectEqual(@as(usize, 2), screen.root.children.len);
    // An omitted field takes its default (color white).
    try testing.expectEqual(@as(f32, 1), screen.root.color[3]);
    try testing.expectEqualStrings("score", screen.root.children[0].bind);
    try testing.expectEqualStrings("lives", screen.root.children[1].bind);
}

test "ui: parse reads the optional id field, defaulting to empty (ADR 0039 §2)" {
    const src =
        \\.{
        \\    .root = .{
        \\        .kind = .container,
        \\        .children = .{
        \\            .{ .kind = .label, .id = "start_button", .focusable = true },
        \\            .{ .kind = .label }, // no id ⇒ anonymous but real
        \\        },
        \\    },
        \\}
    ;
    const screen = try parse(testing.allocator, src);
    defer free(testing.allocator, screen);
    try testing.expectEqualStrings("start_button", screen.root.children[0].id);
    // An unauthored `id` defaults to the empty-string sentinel, like `bind`/`text`.
    try testing.expectEqualStrings("", screen.root.children[1].id);
}

test "ui: parse rejects malformed ZON with ParseZon" {
    const bad = ".{ .name = \"x\" }"; // missing the required `root`
    try testing.expectError(error.ParseZon, parse(testing.allocator, bad));
}

test "ui: layout — the root fills the viewport" {
    const screen: Screen = .{ .root = .{ .kind = .panel } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 640, .h = 480 });
    defer testing.allocator.free(placed);
    try testing.expectEqual(@as(usize, 1), placed.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 640, .h = 480 }, placed[0].rect);
}

test "ui: layout — anchor container positions sized children in its padded content" {
    // A 200×100 viewport, 10px padding ⇒ content is (10,10,180,80). A 40×20 label
    // anchored top-left sits at the content origin; one anchored bottom-right sits at
    // the far corner of the content box.
    const children = [_]Widget{
        .{ .kind = .label, .anchor = .top_left, .width = 40, .height = 20 },
        .{ .kind = .label, .anchor = .bottom_right, .width = 40, .height = 20 },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .anchor, .padding = 10, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 200, .h = 100 });
    defer testing.allocator.free(placed);

    try testing.expectEqual(@as(usize, 3), placed.len); // root + 2 children, pre-order
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 40, .h = 20 }, placed[1].rect);
    // bottom_right: x = 10 + 180 - 40 = 150 ; y = 10 + 80 - 20 = 70.
    try testing.expectEqual(Rect{ .x = 150, .y = 70, .w = 40, .h = 20 }, placed[2].rect);
}

test "ui: layout — flex row splits leftover space among unsized children" {
    // Content 300 wide, one 100px fixed child + two flexible + 10px gap ×2 = 20 gap.
    // leftover = 300 - 100 - 20 = 180, split over 2 flex children = 90 each.
    const children = [_]Widget{
        .{ .kind = .panel, .width = 100 }, // fixed
        .{ .kind = .panel }, // flex
        .{ .kind = .panel }, // flex
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .flex, .direction = .row, .gap = 10, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 300, .h = 50 });
    defer testing.allocator.free(placed);

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 50 }, placed[1].rect);
    try testing.expectEqual(Rect{ .x = 110, .y = 0, .w = 90, .h = 50 }, placed[2].rect);
    try testing.expectEqual(Rect{ .x = 210, .y = 0, .w = 90, .h = 50 }, placed[3].rect);
}

test "ui: layout — flex column stacks children by height with gaps" {
    const children = [_]Widget{
        .{ .kind = .label, .height = 30 },
        .{ .kind = .label, .height = 30 },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .flex, .direction = .column, .gap = 5, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 120, .h = 200 });
    defer testing.allocator.free(placed);

    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 120, .h = 30 }, placed[1].rect);
    try testing.expectEqual(Rect{ .x = 0, .y = 35, .w = 120, .h = 30 }, placed[2].rect);
}

test "ui: hitTest returns the topmost (deepest) widget under a point" {
    const children = [_]Widget{
        .{ .kind = .label, .anchor = .top_left, .width = 40, .height = 40 },
        .{ .kind = .label, .anchor = .bottom_right, .width = 40, .height = 40 },
    };
    const screen: Screen = .{ .root = .{ .kind = .panel, .layout = .anchor, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    defer testing.allocator.free(placed);

    // A point inside the first child hits the child, not the covering root panel.
    try testing.expectEqual(&screen.root.children[0], hitTest(placed, 10, 10).?);
    // A point inside the second child (bottom-right corner region).
    try testing.expectEqual(&screen.root.children[1], hitTest(placed, 90, 90).?);
    // A point on the root but in neither child hits the root panel.
    try testing.expectEqual(&screen.root, hitTest(placed, 50, 50).?);
    // A point outside the viewport hits nothing.
    try testing.expect(hitTest(placed, 200, 200) == null);
}

test "ui: hitTest edge exclusivity — abutting rects never both claim the boundary" {
    const children = [_]Widget{
        .{ .kind = .panel, .width = 50 },
        .{ .kind = .panel, .width = 50 },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .flex, .direction = .row, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    defer testing.allocator.free(placed);
    // x=50 is the exclusive right edge of child 0 and the inclusive left edge of child 1.
    try testing.expectEqual(&screen.root.children[1], hitTest(placed, 50, 10).?);
    try testing.expectEqual(&screen.root.children[0], hitTest(placed, 49, 10).?);
}

test "ui: consumesPointer is true over any widget, false off-screen" {
    const screen: Screen = .{ .root = .{ .kind = .panel } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    defer testing.allocator.free(placed);
    try testing.expect(consumesPointer(placed, 50, 50));
    try testing.expect(!consumesPointer(placed, 500, 500));
}

test "ui: focusOrder collects only focusable widgets, in paint order" {
    const children = [_]Widget{
        .{ .kind = .label, .focusable = false },
        .{ .kind = .label, .focusable = true },
        .{ .kind = .label, .focusable = true },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .flex, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 90, .h = 30 });
    defer testing.allocator.free(placed);

    const order = try focusOrder(testing.allocator, placed);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expectEqual(&screen.root.children[1], order[0].widget);
    try testing.expectEqual(&screen.root.children[2], order[1].widget);
}

test "ui: Focus.next/.prev walk the focus order and wrap at both ends" {
    const children = [_]Widget{
        .{ .kind = .label, .focusable = true },
        .{ .kind = .label, .focusable = true },
        .{ .kind = .label, .focusable = true },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .flex, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 90, .h = 30 });
    defer testing.allocator.free(placed);
    const order = try focusOrder(testing.allocator, placed);
    defer testing.allocator.free(order);

    var focus: Focus = .{};
    try testing.expect(focus.next(order)); // nothing focused ⇒ first
    try testing.expectEqual(&screen.root.children[0], focus.current.?);
    try testing.expect(focus.next(order));
    try testing.expectEqual(&screen.root.children[1], focus.current.?);
    try testing.expect(focus.next(order));
    try testing.expectEqual(&screen.root.children[2], focus.current.?);
    try testing.expect(focus.next(order)); // wraps
    try testing.expectEqual(&screen.root.children[0], focus.current.?);
    try testing.expect(focus.prev(order)); // wraps the other way
    try testing.expectEqual(&screen.root.children[2], focus.current.?);

    var empty_focus: Focus = .{};
    try testing.expect(!empty_focus.next(&.{}));
}

test "ui: Focus.move navigates directionally toward the nearest widget on that axis" {
    // Three focusable buttons in a row: left (x0-20), middle (40-60), right (80-100).
    const children = [_]Widget{
        .{ .kind = .label, .focusable = true, .anchor = .top_left, .width = 20, .height = 20 },
        .{ .kind = .label, .focusable = true, .anchor = .top_center, .width = 20, .height = 20 },
        .{ .kind = .label, .focusable = true, .anchor = .top_right, .width = 20, .height = 20 },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .anchor, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    defer testing.allocator.free(placed);
    const order = try focusOrder(testing.allocator, placed);
    defer testing.allocator.free(order);

    var focus: Focus = .{ .current = order[0].widget }; // start on the left button
    try testing.expect(focus.move(order, .right));
    try testing.expectEqual(order[1].widget, focus.current.?); // middle
    try testing.expect(focus.move(order, .right));
    try testing.expectEqual(order[2].widget, focus.current.?); // right
    try testing.expect(!focus.move(order, .right)); // nothing further right
    try testing.expectEqual(order[2].widget, focus.current.?); // unchanged
    try testing.expect(focus.move(order, .left));
    try testing.expectEqual(order[1].widget, focus.current.?); // back to middle
    try testing.expect(!focus.move(order, .up)); // no vertical candidate
}

test "ui: Focus.focusAt focuses a hit focusable widget, ignores a hit on a non-focusable one" {
    const children = [_]Widget{
        .{ .kind = .panel, .anchor = .top_left, .width = 100, .height = 100, .focusable = false },
        .{ .kind = .label, .anchor = .top_left, .width = 20, .height = 20, .focusable = true },
    };
    const screen: Screen = .{ .root = .{ .kind = .container, .layout = .anchor, .children = &children } };
    const placed = try layout(testing.allocator, &screen, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    defer testing.allocator.free(placed);

    var focus: Focus = .{};
    // Hits the focusable label (topmost at that point).
    try testing.expectEqual(&screen.root.children[1], focus.focusAt(placed, 10, 10).?);
    // Hits only the background panel elsewhere ⇒ no focus change.
    try testing.expect(focus.focusAt(placed, 90, 90) == null);
    try testing.expectEqual(&screen.root.children[1], focus.current.?);
}

test "ui: navDirection maps arrow keys and rejects the rest; isActivateKey classifies enter/space" {
    try testing.expectEqual(NavDirection.up, navDirection(.up).?);
    try testing.expectEqual(NavDirection.down, navDirection(.down).?);
    try testing.expectEqual(NavDirection.left, navDirection(.left).?);
    try testing.expectEqual(NavDirection.right, navDirection(.right).?);
    try testing.expect(navDirection(.space) == null);

    try testing.expect(isActivateKey(.enter));
    try testing.expect(isActivateKey(.space));
    try testing.expect(!isActivateKey(.escape));
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
