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
//!
//! **Capture mode (ADR 0041 §1, issue #235):** `keyEdge`/`padButtonEdge` also check
//! whether `rt` has an action armed for capture (`mana.capture_input`) — one more
//! "UI claims this edge first" rule, ahead of even nav/activate. When armed, the
//! first qualifying **press** edge (a key or gamepad-button press; analog sources are
//! v1-deferred, §1.1) fires `on_input_captured({action, source})` and disarms
//! (one-shot), never reaching focus-nav/activate/gameplay. The armed-action flag lives
//! on `Runtime` itself (`script_runtime.zig`'s `LuaRuntime.capture_armed`) rather than
//! on `UiInput`: `mana.capture_input`/`cancel_capture` reach it through the existing
//! host seam (`HostCtx.captureInput`/`cancelCapture`), and `keyEdge`/`padButtonEdge`
//! already carry `rt` as a parameter to dispatch through — so no new plumbing crosses
//! `ui_dispatch.zig` ↔ `script_runtime.zig` beyond the `Runtime` handle both already
//! share. Hash-excluded exactly like focus/hit-test state (ADR 0041 §5).
//!
//! Past the ~500-line soft limit (CLAUDE.md) by a modest margin, same reasoning as
//! `mana.zig`: this is `UiInput`'s complete dispatch surface plus a behavior test
//! beside each entry point (CLAUDE.md's own testing bar), not accumulated cruft —
//! splitting the capture tests into a separate file would scatter one small,
//! cohesive dispatch-consumption contract across two places for no gain.

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
    /// §3, ADR 0041 §1). Only *press* edges are ever claimed; a release always returns
    /// `false`. **Capture takes priority over everything else**: while `rt` has an
    /// action armed (ADR 0041 §1, `mana.capture_input`), this press edge — whatever key
    /// it is, including one a screen would otherwise treat as nav/activate — is the
    /// qualifying edge: it fires `on_input_captured` with the bare `@tagName` of `key`
    /// as `source`, disarms (one-shot), and is consumed (never reaches `on_focus`/
    /// `on_activate`/gameplay `on_key`). Otherwise, while a screen with a focusable
    /// widget is active: a `navDirection` key drives `Focus.move` (firing `on_focus` on
    /// a change) and is consumed; an `isActivateKey` fires `on_activate` on the focused
    /// widget and is consumed, but only when something is focused (else it falls
    /// through). Every other key returns `false` and reaches gameplay's `on_key` (ADR
    /// 0021) unchanged. Errors as `pointerPress`.
    pub fn keyEdge(self: *UiInput, gpa: Allocator, rt: *Runtime, dc: DispatchCtx, key: platform.Key, pressed: bool) Allocator.Error!bool {
        if (!pressed) return false; // §3/ADR 0041 §1.1: nav/activate/capture ride the press edge only
        if (rt.armedCapture()) |action| {
            try rt.dispatchInputCaptured(action, @tagName(key), dc);
            // One-shot: the first qualifying edge disarms it. Free with `dc.gpa` (the
            // durable sim allocator `mana.capture_input`/`armCapture` duped into), NOT
            // `gpa` — that parameter is the per-tick scratch arena used only for screen
            // layout below; freeing gpa-owned memory through it would be a mismatched
            // free (a crash under the debug allocator).
            rt.clearCapture(dc.gpa);
            return true; // consumed ahead of nav/activate/gameplay (ADR 0041 §1)
        }
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

    /// Route a gamepad-**button** press edge (`button`, `pressed`) against capture
    /// (ADR 0041 §1, §1.1) — the pad-button-source symmetric counterpart of
    /// `keyEdge`'s capture branch. Only a *press* edge is ever claimed; a release
    /// always returns `false`. While `rt` has an action armed, this press is the
    /// qualifying edge: it fires `on_input_captured` with `source` set to
    /// `"pad_" ++ @tagName(button)` (e.g. `"pad_south"`, `"pad_start"`,
    /// `"pad_dpad_up"` — the same vocabulary `input.zon`'s `pad_buttons` lists round-
    /// trip against `platform.GamepadButton`), disarms (one-shot), and is consumed.
    /// When disarmed this always returns `false`: a raw gamepad-button edge has no
    /// nav/activate/gameplay meaning at this dispatch layer today (button *actions*
    /// are diffed and dispatched separately via `on_action`, ADR 0040 §2) — the same
    /// "nothing to claim ⇒ falls through as a no-op" shape `pointerPress` already has
    /// for an unhit point. Errors as `keyEdge` (an OOM from the dispatched handler's
    /// queued mutations). Unlike `keyEdge`/`pointerPress` this takes no scratch
    /// allocator: capture lays out no screen, so there is nothing to allocate — the
    /// armed-action buffer is freed with the durable `dc.gpa` it was duped into.
    pub fn padButtonEdge(self: *UiInput, rt: *Runtime, dc: DispatchCtx, button: platform.GamepadButton, pressed: bool) Allocator.Error!bool {
        _ = self; // capture is orthogonal to the active screen/focus state
        if (!pressed) return false;
        const action = rt.armedCapture() orelse return false;
        // The `pad_` prefix encodes the source *kind*: keys and pad buttons share one
        // flat `source` string namespace, so a bare `@tagName` ("south") would collide
        // with a key name and lose which device it came from. Keys stay bare (no
        // translation — they already match `input.zon`'s `keys` enum literals); pad
        // buttons get `pad_` so `"pad_south"` is unambiguously a button. NOTE for the
        // phase-4 persistence driver (#238): it must **strip** this `pad_` prefix before
        // writing the override `input.zon`, whose `pad_buttons` list holds bare enum
        // literals (`.south`, not `"pad_south"`); keys need no such stripping.
        var buf: [24]u8 = undefined;
        const source = std.fmt.bufPrint(&buf, "pad_{s}", .{@tagName(button)}) catch unreachable; // fits: longest tag "right_shoulder" + "pad_" < 24
        try rt.dispatchInputCaptured(action, source, dc);
        // One-shot: free with `dc.gpa` (the durable allocator `armCapture` duped into),
        // never a scratch arena — see `keyEdge`'s clear for the same reasoning.
        rt.clearCapture(dc.gpa);
        return true;
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

    // ADR 0041 §1 regression: with nothing armed for capture (the default, and the
    // only reachable state with no `mana` surface to arm from), a gamepad-button
    // edge — press or release — is always a no-op, any build.
    try testing.expect(!try input.padButtonEdge(&rt, dc, .south, true));
    try testing.expect(!try input.padButtonEdge(&rt, dc, .south, false));
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

// --- Capture mode (ADR 0041 §1, issue #235) ---------------------------------------

/// Mirrors `Sim.tick`'s key-edge orchestration (ADR 0039 §3 / ADR 0021): route the
/// edge through `UiInput` first; only when it consumes nothing does gameplay's
/// `on_key` see it. Test-only glue so a capture test can honestly prove "a
/// consumed edge never reaches on_key" rather than merely asserting `keyEdge`'s
/// return value. Returns whether the UI consumed the edge (same as `keyEdge`).
fn routeKey(input: *UiInput, gpa: Allocator, rt: *Runtime, dc: DispatchCtx, key: platform.Key, pressed: bool) !bool {
    const consumed = try input.keyEdge(gpa, rt, dc, key, pressed);
    if (!consumed) try rt.dispatchKey(@tagName(key), pressed, dc);
    return consumed;
}

test "ui_dispatch: capture — armed via mana.capture_input, a key press edge fires on_input_captured and is consumed ahead of nav/activate/gameplay on_key" {
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
        \\local t = { clicks = 0, captures = 0, action_ok = 0, source_ok = 0, key_presses = 0 }
        \\function t.on_click(ev) t.clicks = t.clicks + 1; mana.capture_input("jump") end
        \\function t.on_input_captured(ev)
        \\  t.captures = t.captures + 1
        \\  if ev.action == "jump" then t.action_ok = 1 end
        \\  if ev.source == "w" then t.source_ok = 1 end
        \\end
        \\function t.on_key(ev) if ev.pressed then t.key_presses = t.key_presses + 1 end end
        \\return t
    );

    var input: UiInput = .{};
    input.setScreen(&two_button_row, .{ .x = 0, .y = 0, .w = 100, .h = 20 });

    // A click on "a" arms capture for "jump" from inside its on_click handler — the
    // real controls-screen shape (a "rebind" widget's click arms capture).
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("clicks").?);

    // A release edge never qualifies (ADR 0041 §1.1) — capture stays armed, nothing
    // dispatches, and (since armed capture claims every press ahead of nav/activate/
    // gameplay) a release is simply never claimed by anything at this layer either.
    try testing.expect(!try routeKey(&input, testing.allocator, &rt, dc, .w, false));
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("captures").?);

    // The next press edge — "w", which has no nav/activate meaning for this screen
    // anyway — is the qualifying edge: on_input_captured fires with the right
    // {action, source}, and on_key never sees it (consumed).
    try testing.expect(try routeKey(&input, testing.allocator, &rt, dc, .w, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("captures").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("action_ok").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("source_ok").?);
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("key_presses").?);

    // Capture is one-shot: now disarmed, a further press falls through to gameplay
    // on_key exactly as before capture existed.
    try testing.expect(!try routeKey(&input, testing.allocator, &rt, dc, .a, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("captures").?); // unchanged
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("key_presses").?);

    // Capture also wins over a screen's own activate key: re-arm, then press Enter
    // (normally isActivateKey) — it must be captured, not fire on_activate.
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10)); // re-arm "jump"
    try testing.expect(try routeKey(&input, testing.allocator, &rt, dc, .enter, true));
    try testing.expectEqual(@as(i64, 2), rt.handlerFieldInt("captures").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("key_presses").?); // unchanged: still consumed
}

test "ui_dispatch: capture — re-arming replaces the pending action, and mana.cancel_capture disarms without binding" {
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
        \\local t = { captures = 0, saw_jump = 0, saw_walk = 0, key_presses = 0 }
        \\function t.on_click(ev)
        \\  if ev.id == "a" then mana.capture_input("jump") end
        \\  if ev.id == "b" then mana.capture_input("walk") end
        \\end
        \\function t.on_input_captured(ev)
        \\  t.captures = t.captures + 1
        \\  if ev.action == "jump" then t.saw_jump = 1 end
        \\  if ev.action == "walk" then t.saw_walk = 1 end
        \\end
        \\function t.on_key(ev) if ev.pressed then t.key_presses = t.key_presses + 1 end end
        \\return t
    );

    var input: UiInput = .{};
    input.setScreen(&two_button_row, .{ .x = 0, .y = 0, .w = 100, .h = 20 });

    // Arm "jump" (click "a"), then re-arm "walk" (click "b") before any edge
    // arrives: re-arming replaces the pending target, it does not queue both.
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10)); // "a" ⇒ jump
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 60, 10)); // "b" ⇒ walk
    try testing.expect(try routeKey(&input, testing.allocator, &rt, dc, .d, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("captures").?);
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("saw_jump").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("saw_walk").?);

    // Now exercise mana.cancel_capture: arm "jump" again, then load a script path
    // that cancels instead of a key arriving — a subsequent press must fall
    // straight through to gameplay on_key, never firing on_input_captured.
    try rt.loadHandlers(testing.allocator,
        \\local t = { captures = 0, key_presses = 0 }
        \\function t.on_click(ev)
        \\  if ev.id == "a" then mana.capture_input("jump") end
        \\  if ev.id == "b" then mana.cancel_capture() end
        \\end
        \\function t.on_input_captured(ev) t.captures = t.captures + 1 end
        \\function t.on_key(ev) if ev.pressed then t.key_presses = t.key_presses + 1 end end
        \\return t
    );
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10)); // "a" ⇒ arm "jump"
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 60, 10)); // "b" ⇒ cancel
    try testing.expect(!try routeKey(&input, testing.allocator, &rt, dc, .s, true)); // falls through
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("captures").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("key_presses").?);
}

test "ui_dispatch: capture — a gamepad-button press edge fires on_input_captured with a pad_-prefixed source" {
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
        \\local t = { captures = 0, action_ok = 0, source_ok = 0 }
        \\function t.on_click(ev) mana.capture_input("jump") end
        \\function t.on_input_captured(ev)
        \\  t.captures = t.captures + 1
        \\  if ev.action == "jump" then t.action_ok = 1 end
        \\  if ev.source == "pad_south" then t.source_ok = 1 end
        \\end
        \\return t
    );

    var input: UiInput = .{};
    input.setScreen(&two_button_row, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try testing.expect(try input.pointerPress(testing.allocator, &rt, dc, 10, 10)); // arm "jump"

    // A release edge never triggers capture.
    try testing.expect(!try input.padButtonEdge(&rt, dc, .south, false));
    try testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("captures").?);

    // The qualifying press edge fires on_input_captured with a pad_-prefixed source.
    try testing.expect(try input.padButtonEdge(&rt, dc, .south, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("captures").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("action_ok").?);
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("source_ok").?);

    // Disarmed now: a further pad-button press claims nothing at this layer (raw
    // pad-button edges have no nav/gameplay meaning here; named button *actions*
    // are diffed and dispatched separately via on_action, ADR 0040 §2).
    try testing.expect(!try input.padButtonEdge(&rt, dc, .start, true));
    try testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("captures").?);
}
