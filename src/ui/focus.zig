//! Keyboard/gamepad focus navigation over a `types.zig` `layout` result (ADR 0034 §8;
//! issue #134, hit-test/focus half; split out of `ui.zig` per issue #151): `NavDirection`
//! + `navDirection` map an arrow key, `isActivateKey` classifies the "confirm" key, and
//! `Focus` tracks/moves the focused widget (`next`/`prev`/directional `move`/pointer-driven
//! `focusAt`). Imports `types.zig` for the shared `Rect`/`Placed`/`Widget`/`hitTest` it
//! walks — never the other way, so `types.zig` stays free of focus-state concerns.

const std = @import("std");
const platform = @import("platform");
const types = @import("types.zig");

const Placed = types.Placed;
const Widget = types.Widget;
const Rect = types.Rect;
const hitTest = types.hitTest;

/// A screen-space direction for directional focus navigation (ADR 0034 §8, issue #134).
/// Named distinctly from `types.Direction` (a `flex` container's main axis) — this is
/// about *where on screen* focus moves, not how children are laid out.
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

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;
const layout = types.layout;
const focusOrder = types.focusOrder;
const Screen = types.Screen;

test "ui.focus: Focus.next/.prev walk the focus order and wrap at both ends" {
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

test "ui.focus: Focus.move navigates directionally toward the nearest widget on that axis" {
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

test "ui.focus: Focus.focusAt focuses a hit focusable widget, ignores a hit on a non-focusable one" {
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

test "ui.focus: navDirection maps arrow keys and rejects the rest; isActivateKey classifies enter/space" {
    try testing.expectEqual(NavDirection.up, navDirection(.up).?);
    try testing.expectEqual(NavDirection.down, navDirection(.down).?);
    try testing.expectEqual(NavDirection.left, navDirection(.left).?);
    try testing.expectEqual(NavDirection.right, navDirection(.right).?);
    try testing.expect(navDirection(.space) == null);

    try testing.expect(isActivateKey(.enter));
    try testing.expect(isActivateKey(.space));
    try testing.expect(!isActivateKey(.escape));
}
