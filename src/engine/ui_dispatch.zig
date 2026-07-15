//! ui_dispatch — routes synthetic UI input edges to the script runtime (ADR 0039).
//!
//! This is Phase B of issue #134: the **dispatch layer** on top of #182's already-
//! shipped `ui` primitives (`hitTest`/`consumesPointer`/`Focus`). `UiInput` holds the
//! one active screen (ADR 0039 §6 single-screen model) and its focus state, and turns
//! discrete pointer/keyboard edges into `on_click`/`on_focus`/`on_activate` dispatches
//! against the Sim's one handler table, applying the §3 ordering rule: **UI consumes an
//! input first; gameplay sees only what the UI did not claim.** Each entry point returns
//! whether the UI consumed the edge, so a caller routes the same edge to gameplay
//! (`on_key`, a future pointer path) only on `false`.
//!
//! **Event-driven, never per-frame per-widget** (invariant; ADR 0039 §1): the engine
//! calls these on an *edge* (a press, a nav key), and Lua sets data the engine consumes
//! — no polling loop, no per-widget Lua callback. **Cosmetic and hash-excluded** (ADR
//! 0039 §4): the focus/hit-test state driving dispatch never enters `World.stateHash`;
//! only whatever a handler *body* queues on the command buffer is gameplay state. Under
//! a default (no-Lua) build `Runtime` is the inert `NoopRuntime`, so the focus math
//! still runs (and stays testable) while every dispatch is a comptime no-op.

const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const script_runtime = @import("script_runtime.zig");

const Allocator = std.mem.Allocator;
const Runtime = script_runtime.Runtime;
const DispatchCtx = script_runtime.DispatchCtx;

/// The one active UI screen plus its live focus state, and the sink that turns input
/// edges into ADR 0039 event dispatches. Holds no allocations itself: each entry point
/// lays the screen out through a caller-supplied allocator for the duration of the call
/// (an edge is rare, so this is not a hot-loop allocation), so the struct stays a small
/// plain value the Sim can own by value. `screen` borrows a `ui.Screen` the caller keeps
/// alive for as long as it is the active screen.
pub const UiInput = struct {
    /// The active screen, or `null` when no UI is up (every entry point then consumes
    /// nothing, so input falls straight through to gameplay). ADR 0039 §6: one screen.
    screen: ?*const ui.Screen = null,
    /// The viewport rect the active screen lays out within (screen pixels; the same
    /// space pointer coordinates arrive in).
    viewport: ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Which focusable widget currently holds focus (cosmetic; never hashed, ADR 0039 §4).
    focus: ui.Focus = .{},
    /// The widget-handle generation stamped into every dispatched handle (ADR 0039 §2),
    /// bumped once per `setScreen` (a screen load/hot-reload) so a handle held across a
    /// reload reads as stale — the widget-side analogue of an entity handle's generation.
    generation: u32 = 0,

    /// Make `screen` the active screen laid out within `viewport`, resetting focus and
    /// bumping the widget-handle generation (ADR 0039 §2: handles from the previous
    /// screen become stale). Call on a screen load or hot-reload.
    pub fn setScreen(self: *UiInput, screen: *const ui.Screen, viewport: ui.Rect) void {
        self.screen = screen;
        self.viewport = viewport;
        self.focus = .{};
        self.generation +%= 1;
    }

    /// Drop the active screen (no UI up): subsequent edges consume nothing. Focus is
    /// cleared; the generation is left as-is (the next `setScreen` bumps it).
    pub fn clearScreen(self: *UiInput) void {
        self.screen = null;
        self.focus = .{};
    }

    /// Route a pointer **press** at screen point (`x`, `y`) (ADR 0039 §3): if it lands
    /// on a hit widget the UI dispatches `on_click` (and, when that widget is focusable,
    /// moves focus onto it, firing `on_focus` on any change) and returns `true` — the
    /// press is consumed, gameplay does not additionally see it. If the point hits no
    /// widget the UI consumes nothing and returns `false` (the press falls through). The
    /// screen is laid out through `gpa` for this call only. Errors: `OutOfMemory` (from
    /// layout or a handler's queued mutation hitting OOM — never a content bug).
    pub fn pointerPress(self: *UiInput, gpa: Allocator, rt: *Runtime, dc: DispatchCtx, x: f32, y: f32) Allocator.Error!bool {
        const screen = self.screen orelse return false;
        const placed = try ui.layout(gpa, screen, self.viewport);
        defer gpa.free(placed);
        const hit = ui.hitTest(placed, x, y) orelse return false; // UI claims nothing
        // §3 leads with the click; the focus change (if any) is its consequence.
        try rt.dispatchClick(indexOf(placed, hit), self.generation, hit.id, x, y, dc);
        if (hit.focusable) {
            const before = self.focus.current;
            _ = self.focus.focusAt(placed, x, y);
            try self.dispatchFocusChange(rt, dc, placed, before);
        }
        return true;
    }

    /// Route a keyboard **edge** (`key`, `pressed`) against the active screen (ADR 0039
    /// §3). Only *press* edges are ever claimed; a release always returns `false`. While
    /// a screen with a focusable widget is active: a `navDirection` key drives
    /// `Focus.move` (firing `on_focus` on a change) and is consumed; an `isActivateKey`
    /// fires `on_activate` on the focused widget and is consumed, but only when something
    /// is focused (else it falls through). Every other key returns `false` and reaches
    /// gameplay's `on_key` (ADR 0021) unchanged. Errors as `pointerPress`.
    pub fn keyEdge(self: *UiInput, gpa: Allocator, rt: *Runtime, dc: DispatchCtx, key: platform.Key, pressed: bool) Allocator.Error!bool {
        if (!pressed) return false; // §3: nav/activate ride the press edge only
        const screen = self.screen orelse return false;
        const placed = try ui.layout(gpa, screen, self.viewport);
        defer gpa.free(placed);
        const order = try ui.focusOrder(gpa, placed);
        defer gpa.free(order);
        if (order.len == 0) return false; // no focusable widget: the screen claims nothing

        if (ui.navDirection(key)) |dir| {
            const before = self.focus.current;
            _ = self.focus.move(order, dir);
            try self.dispatchFocusChange(rt, dc, placed, before);
            return true; // the screen claims a recognized nav press edge, moved or not
        }
        if (ui.isActivateKey(key)) {
            const w = self.focus.current orelse return false; // nothing focused: fall through
            try rt.dispatchActivate(indexOf(placed, w), self.generation, w.id, dc);
            return true;
        }
        return false; // an unclaimed key falls through to gameplay `on_key`
    }

    /// Fire `on_focus` for the newly focused widget iff focus changed from `before`
    /// (ADR 0039 §1: the event fires on a transition to a *new* target). A no-op when
    /// focus is unchanged or was cleared. `placed` is the layout the new focus came from.
    fn dispatchFocusChange(self: *UiInput, rt: *Runtime, dc: DispatchCtx, placed: []const ui.Placed, before: ?*const ui.Widget) Allocator.Error!void {
        if (self.focus.current == before) return;
        const w = self.focus.current orelse return;
        try rt.dispatchFocus(indexOf(placed, w), self.generation, w.id, dc);
    }

    /// The widget-handle index of `w`: its position in `placed`, the deterministic
    /// pre-order `layout` produces (ADR 0039 §2). `w` always originates from this same
    /// `placed` slice — it is a `hitTest`/`Focus`/`focusOrder` result over it — so the
    /// scan always finds it.
    fn indexOf(placed: []const ui.Placed, w: *const ui.Widget) u32 {
        for (placed, 0..) |p, i| if (p.widget == w) return @intCast(i);
        unreachable; // `w` is by construction a widget drawn from `placed`
    }
};

// --- Tests ------------------------------------------------------------------------
//
// The focus-navigation/consumption test below runs under BOTH builds: with no handler
// table loaded, every `rt.dispatch*` is a no-op (a null-state `LuaRuntime`, or the
// `NoopRuntime`), so the focus math and the §3 consumption rule are exercised without
// Lua. The handler-fired test is gated to `-Denable-lua`, since only then is there a
// real interpreter to observe a handler running.

const testing = std.testing;
const script = @import("script");
const core = @import("core");
const World = @import("world.zig").World;
const command = @import("command.zig");
const timer = @import("timer.zig");

/// A row of two fixed-width focusable buttons filling a 100×20 viewport: button "a"
/// spans x∈[0,50), button "b" x∈[50,100). Pre-order layout ⇒ placed[0]=root,
/// placed[1]=a, placed[2]=b, so the widget-handle indices are a known 1 and 2.
const two_button_row: ui.Screen = .{ .root = .{
    .kind = .container,
    .layout = .flex,
    .direction = .row,
    .children = &[_]ui.Widget{
        .{ .kind = .label, .id = "a", .focusable = true, .width = 50 },
        .{ .kind = .label, .id = "b", .focusable = true, .width = 50 },
    },
} };

test "ui_dispatch: focus navigation and the §3 consumption rule (no handlers, any build)" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var commands: command.CommandBuffer = .{};
    defer commands.deinit(testing.allocator);
    var timers: timer.Timers = .{};
    defer timers.deinit(testing.allocator);
    var rng: core.Rng = core.Rng.init(0);
    const dc: DispatchCtx = .{
        .world = &world,
        .commands = &commands,
        .gpa = testing.allocator,
        .now_seconds = 0,
        .timers = &timers,
        .rng = &rng,
    };
    var rt: Runtime = .{}; // no handler table: dispatch is a no-op, focus math still runs
    defer rt.deinit(testing.allocator);

    var input: UiInput = .{};
    // With no active screen, nothing is consumed — input falls through to gameplay.
    try testing.expect(!try input.keyEdge(testing.allocator, &rt, dc, .right, true));
    try testing.expect(!try input.pointerPress(testing.allocator, &rt, dc, 10, 10));

    input.setScreen(&two_button_row, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try testing.expectEqual(@as(u32, 1), input.generation);

    // A right-arrow press with nothing focused bootstraps focus onto the first button
    // and is consumed (the screen claims the nav edge, §3).
    try testing.expect(try input.keyEdge(testing.allocator, &rt, dc, .right, true));
    try testing.expectEqual(&two_button_row.root.children[0], input.focus.current.?);
    // A release edge is never claimed (§3: press edge only).
    try testing.expect(!try input.keyEdge(testing.allocator, &rt, dc, .right, false));
    // Next right-arrow moves onto the second button.
    try testing.expect(try input.keyEdge(testing.allocator, &rt, dc, .right, true));
    try testing.expectEqual(&two_button_row.root.children[1], input.focus.current.?);

    // A non-nav, non-activate key is not claimed — it must reach gameplay `on_key`.
    try testing.expect(!try input.keyEdge(testing.allocator, &rt, dc, .escape, true));

    // A pointer press on button "a" is consumed and moves focus back onto it.
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10));
    try testing.expectEqual(&two_button_row.root.children[0], input.focus.current.?);
    // A press off any widget consumes nothing.
    input.clearScreen();
    try testing.expect(!try input.pointerPress(testing.allocator, &rt, dc, 10, 10));
}

test "ui_dispatch: input edges fire on_click/on_focus/on_activate with the right handle" {
    if (!script.lua_enabled) return error.SkipZigTest;

    var world = World.init(testing.allocator);
    defer world.deinit();
    var commands: command.CommandBuffer = .{};
    defer commands.deinit(testing.allocator);
    var timers: timer.Timers = .{};
    defer timers.deinit(testing.allocator);
    var rng: core.Rng = core.Rng.init(0);
    const dc: DispatchCtx = .{
        .world = &world,
        .commands = &commands,
        .gpa = testing.allocator,
        .now_seconds = 0,
        .timers = &timers,
        .rng = &rng,
    };

    var rt: Runtime = .{};
    defer rt.deinit(testing.allocator);
    try rt.loadHandlers(testing.allocator,
        \\local t = { clicks = 0, focuses = 0, activates = 0, click_widget = 0, click_a = 0 }
        \\function t.on_click(ev)
        \\  t.clicks = t.clicks + 1
        \\  t.click_widget = ev.widget
        \\  if ev.id == "a" then t.click_a = 1 end
        \\end
        \\function t.on_focus(ev) t.focuses = t.focuses + 1 end
        \\function t.on_activate(ev) t.activates = t.activates + 1 end
        \\return t
    );

    var input: UiInput = .{};
    input.setScreen(&two_button_row, .{ .x = 0, .y = 0, .w = 100, .h = 20 });

    // Click button "a" (widget index 1, generation 1): fires on_click, and focus
    // null→a fires on_focus once.
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10));
    const expect_a: i64 = @bitCast(@as(u64, 1) << 32 | 1); // generation 1, index 1
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("clicks").?);
    try testing.expectEqual(expect_a, rt.handlerFieldInt("click_widget").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("click_a").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("focuses").?);

    // Right-arrow moves focus a→b: a second on_focus.
    try testing.expect(try input.keyEdge(testing.allocator, &rt, dc, .right, true));
    try testing.expectEqual(@as(i64, 2), rt.handlerFieldInt("focuses").?);

    // Enter activates the focused widget: on_activate fires once.
    try testing.expect(try input.keyEdge(testing.allocator, &rt, dc, .enter, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("activates").?);
}
