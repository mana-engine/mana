//! Headless platform adapter — the real default (ADR 0009): a `Window` with no OS
//! dependency. It opens no display, produces no OS input, and exposes a null native
//! surface handle, so the sim + null gpu backend run windowless in CI. Its method
//! shapes mirror the (deferred) SDL3 adapter's `Window`, so `engine`'s loop is
//! adapter-agnostic; the SDL3 adapter stays a compile stub until its dependency lands.

const std = @import("std");
const port = @import("../port.zig");
const Allocator = std.mem.Allocator;

/// A headless window: no OS resources. `should_close` is driven by the caller (a
/// tick budget or an external `--watch` signal via `requestClose`), `poll` returns
/// `scripted_input` (all-zero unless a harness injects a stream — ADR 0009's
/// input-replay seam), and `surfaceHandle` is null (no OS window ⇒ the null gpu
/// swapchain's headless path). Plain value; owns nothing.
pub const Window = struct {
    width: u32,
    height: u32,
    should_close: bool = false,
    /// Snapshot returned by the next `poll`; defaults to empty (no keys held, no
    /// gamepad connected, all axes zero). A test/replay harness sets it to scripted
    /// input one tick at a time (ADR 0009 §2/§4) — including gamepad buttons/axes/
    /// connected state (ADR 0040 §5), the same seam as keyboard `keys`, since both
    /// live on the one `port.InputSnapshot` value.
    scripted_input: port.InputSnapshot = .{},

    /// Open a headless window sized by `config`. `gpa` is accepted for signature
    /// parity with the SDL3 adapter (which allocates OS state); headless ignores it.
    /// Never fails; `!Window` matches the fallible SDL3 `open`. `config.title` is not
    /// retained.
    pub fn open(gpa: Allocator, config: port.WindowConfig) !Window {
        _ = gpa;
        return .{ .width = config.width, .height = config.height };
    }

    /// Release the window. No-op: headless owns no OS resources.
    pub fn close(self: *Window) void {
        _ = self;
    }

    /// Whether the loop should exit. Headless: the caller-controlled flag (set via
    /// `requestClose`, e.g. when a tick budget is exhausted).
    pub fn shouldClose(self: *const Window) bool {
        return self.should_close;
    }

    /// Request that the next `shouldClose` return true (tick-budget / `--watch` signal).
    pub fn requestClose(self: *Window) void {
        self.should_close = true;
    }

    /// Set the window title — a no-op headless (there is no OS window). Present so
    /// runtime code (the play loop's FPS readout) is adapter-agnostic.
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = self;
        _ = title;
    }

    /// Sample this frame's input. Headless returns `scripted_input` (empty unless a
    /// harness injected a snapshot); real OS input is the SDL3 adapter's job.
    pub fn poll(self: *Window) port.InputSnapshot {
        return self.scripted_input;
    }

    /// Current drawable size in pixels.
    pub fn size(self: *const Window) [2]u32 {
        return .{ self.width, self.height };
    }

    /// Resize the headless window's drawable (simulates an OS resize event, so the gpu
    /// swapchain's `resize` path is exercisable headlessly).
    pub fn resize(self: *Window, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    /// The opaque native surface handle for the `gpu` port. Headless has no OS window,
    /// so this is null — the null gpu backend's swapchain accepts a null surface. The
    /// SDL3 adapter returns its `SDL_Window*` here; `gpu` (not `platform`) turns that
    /// into a Vulkan surface, so no Vulkan type crosses this boundary. Lifetime: valid
    /// while the `Window` is open.
    pub fn surfaceHandle(self: *const Window) ?*anyopaque {
        _ = self;
        return null;
    }
};

const testing = std.testing;

test "headless window: open, poll input, resize, request close" {
    var win = try Window.open(testing.allocator, .{ .title = "t", .width = 320, .height = 240, .resizable = true });
    defer win.close();

    try testing.expectEqual([2]u32{ 320, 240 }, win.size());
    try testing.expect(!win.shouldClose());
    try testing.expectEqual(@as(?*anyopaque, null), win.surfaceHandle());

    // Empty snapshot by default.
    const empty = win.poll();
    try testing.expectEqual(@as(usize, 0), empty.keys.count());
    try testing.expectEqual(@as(f32, 0), empty.wheel);

    // Scripted input is returned as-is (the replay seam).
    var scripted = port.InputSnapshot{};
    scripted.keys.insert(.up);
    win.scripted_input = scripted;
    try testing.expect(win.poll().keys.contains(.up));

    // Resize updates the drawable size (feeds the gpu swapchain resize path).
    win.resize(640, 480);
    try testing.expectEqual([2]u32{ 640, 480 }, win.size());

    win.requestClose();
    try testing.expect(win.shouldClose());
}

test "headless window: no gamepad injected ⇒ disconnected, no buttons, zeroed axes" {
    var win = try Window.open(testing.allocator, .{ .width = 320, .height = 240 });
    defer win.close();

    const snap = win.poll();
    try testing.expect(!snap.pad_connected);
    try testing.expectEqual(@as(usize, 0), snap.pad_buttons.count());
    try testing.expectEqual(@as(f32, 0), snap.pad_axes.get(.left_x));
    try testing.expectEqual(@as(f32, 0), snap.pad_axes.get(.right_trigger));
}

test "headless window: scripted gamepad buttons round-trip through poll" {
    var win = try Window.open(testing.allocator, .{ .width = 320, .height = 240 });
    defer win.close();

    var scripted = port.InputSnapshot{};
    scripted.pad_connected = true;
    scripted.pad_buttons.insert(.south);
    scripted.pad_buttons.insert(.dpad_up);
    win.scripted_input = scripted;

    const snap = win.poll();
    try testing.expect(snap.pad_connected);
    try testing.expect(snap.pad_buttons.contains(.south));
    try testing.expect(snap.pad_buttons.contains(.dpad_up));
    try testing.expect(!snap.pad_buttons.contains(.east));
}

test "headless window: scripted gamepad axes round-trip, including negative stick and [0,1] trigger" {
    var win = try Window.open(testing.allocator, .{ .width = 320, .height = 240 });
    defer win.close();

    var scripted = port.InputSnapshot{};
    scripted.pad_connected = true;
    scripted.pad_axes.set(.left_x, -0.75);
    scripted.pad_axes.set(.left_y, 0.5);
    scripted.pad_axes.set(.right_trigger, 1.0);
    win.scripted_input = scripted;

    const snap = win.poll();
    try testing.expectEqual(@as(f32, -0.75), snap.pad_axes.get(.left_x));
    try testing.expectEqual(@as(f32, 0.5), snap.pad_axes.get(.left_y));
    try testing.expectEqual(@as(f32, 1.0), snap.pad_axes.get(.right_trigger));
    // Untouched axes stay at their zeroed default.
    try testing.expectEqual(@as(f32, 0), snap.pad_axes.get(.right_x));
}

test "headless window: pad_connected toggles independently of button/axis state" {
    var win = try Window.open(testing.allocator, .{ .width = 320, .height = 240 });
    defer win.close();

    var scripted = port.InputSnapshot{};
    scripted.pad_connected = true;
    win.scripted_input = scripted;
    try testing.expect(win.poll().pad_connected);

    scripted.pad_connected = false;
    win.scripted_input = scripted;
    try testing.expect(!win.poll().pad_connected);
}
