//! SDL3 platform adapter — the first real (non-headless) `Window` (ADR 0009): a real
//! OS window with real keyboard/mouse input, built on SDL3 (compiled from source via
//! the `sdl` dependency, gated behind `-Denable-sdl3`). Its `Window` surface mirrors
//! the headless adapter method-for-method so `engine`'s loop stays adapter-agnostic.
//!
//! Boundary (CLAUDE.md #4 / ADR 0009): this file imports only `core` (indirectly, via
//! the port), the port vocabulary, and SDL3 — never `gpu` or `vulkan`. `surfaceHandle`
//! returns the native `SDL_Window*` as an opaque `?*anyopaque`; the `gpu` port (not
//! `platform`) is what later turns that into a `VkSurfaceKHR` (phase 2), so no Vulkan
//! type ever crosses this boundary.

const std = @import("std");
const build_options = @import("build_options");
const port = @import("../port.zig");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// Maps each engine-owned `port.Key` to its SDL scancode index. `poll` samples the
/// keyboard-state array at these indices, so this table is the single source of the
/// arrow keys (and WASD) a top-down mover needs; a comptime test asserts it covers
/// every `port.Key`, so a newly-added key can never be silently unmapped.
const key_map = blk: {
    const E = struct { key: port.Key, scancode: usize };
    break :blk [_]E{
        .{ .key = .up, .scancode = @intCast(c.SDL_SCANCODE_UP) },
        .{ .key = .down, .scancode = @intCast(c.SDL_SCANCODE_DOWN) },
        .{ .key = .left, .scancode = @intCast(c.SDL_SCANCODE_LEFT) },
        .{ .key = .right, .scancode = @intCast(c.SDL_SCANCODE_RIGHT) },
        .{ .key = .w, .scancode = @intCast(c.SDL_SCANCODE_W) },
        .{ .key = .a, .scancode = @intCast(c.SDL_SCANCODE_A) },
        .{ .key = .s, .scancode = @intCast(c.SDL_SCANCODE_S) },
        .{ .key = .d, .scancode = @intCast(c.SDL_SCANCODE_D) },
        .{ .key = .space, .scancode = @intCast(c.SDL_SCANCODE_SPACE) },
        .{ .key = .enter, .scancode = @intCast(c.SDL_SCANCODE_RETURN) },
        .{ .key = .escape, .scancode = @intCast(c.SDL_SCANCODE_ESCAPE) },
    };
};

/// SDL button number → its state-mask bit (`SDL_GetMouseState` bitmask). SDL numbers
/// buttons from 1 (left=1, middle=2, right=3); the mask bit is `1 << (button - 1)`.
fn buttonMask(comptime button: c_int) u32 {
    return @as(u32, 1) << @intCast(button - 1);
}

/// Maps each engine-owned `port.GamepadButton` to its SDL standardized button code
/// (ADR 0040 §5). `poll` samples `SDL_GetGamepadButton` at these codes, so this table
/// is the single source of the mapping; a comptime test asserts it covers every
/// `port.GamepadButton`, mirroring `key_map`'s coverage guarantee.
const gamepad_button_map = blk: {
    const E = struct { button: port.GamepadButton, sdl: c_int };
    break :blk [_]E{
        .{ .button = .south, .sdl = c.SDL_GAMEPAD_BUTTON_SOUTH },
        .{ .button = .east, .sdl = c.SDL_GAMEPAD_BUTTON_EAST },
        .{ .button = .west, .sdl = c.SDL_GAMEPAD_BUTTON_WEST },
        .{ .button = .north, .sdl = c.SDL_GAMEPAD_BUTTON_NORTH },
        .{ .button = .dpad_up, .sdl = c.SDL_GAMEPAD_BUTTON_DPAD_UP },
        .{ .button = .dpad_down, .sdl = c.SDL_GAMEPAD_BUTTON_DPAD_DOWN },
        .{ .button = .dpad_left, .sdl = c.SDL_GAMEPAD_BUTTON_DPAD_LEFT },
        .{ .button = .dpad_right, .sdl = c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT },
        .{ .button = .left_shoulder, .sdl = c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER },
        .{ .button = .right_shoulder, .sdl = c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER },
        .{ .button = .left_stick, .sdl = c.SDL_GAMEPAD_BUTTON_LEFT_STICK },
        .{ .button = .right_stick, .sdl = c.SDL_GAMEPAD_BUTTON_RIGHT_STICK },
        .{ .button = .start, .sdl = c.SDL_GAMEPAD_BUTTON_START },
        .{ .button = .back, .sdl = c.SDL_GAMEPAD_BUTTON_BACK },
        .{ .button = .guide, .sdl = c.SDL_GAMEPAD_BUTTON_GUIDE },
    };
};

/// Whether an SDL gamepad axis is a centered stick axis (`[-32768, 32767]`, normalized
/// to `[-1, 1]`) or a one-sided trigger axis (`[0, 32767]`, normalized to `[0, 1]`) —
/// the two need different normalization (`normalizeAxis`).
const AxisKind = enum { stick, trigger };

/// Maps each engine-owned `port.GamepadAxis` to its SDL standardized axis code and
/// `AxisKind` (ADR 0040 §5). A comptime test asserts it covers every `port.GamepadAxis`.
const gamepad_axis_map = blk: {
    const E = struct { axis: port.GamepadAxis, sdl: c_int, kind: AxisKind };
    break :blk [_]E{
        .{ .axis = .left_x, .sdl = c.SDL_GAMEPAD_AXIS_LEFTX, .kind = .stick },
        .{ .axis = .left_y, .sdl = c.SDL_GAMEPAD_AXIS_LEFTY, .kind = .stick },
        .{ .axis = .right_x, .sdl = c.SDL_GAMEPAD_AXIS_RIGHTX, .kind = .stick },
        .{ .axis = .right_y, .sdl = c.SDL_GAMEPAD_AXIS_RIGHTY, .kind = .stick },
        .{ .axis = .left_trigger, .sdl = c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER, .kind = .trigger },
        .{ .axis = .right_trigger, .sdl = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, .kind = .trigger },
    };
};

/// Normalize a raw `SDL_GetGamepadAxis` `Sint16` reading to the engine's `[-1, 1]`
/// (stick) / `[0, 1]` (trigger) convention (ADR 0040 §5, issue #215).
///
/// SDL sticks report `-32768..32767` (asymmetric two's-complement range); dividing
/// negative readings by 32768 and non-negative readings by 32767 makes both endpoints
/// land exactly on `-1.0`/`1.0` instead of stopping just short at the positive end.
/// **Sign convention (SDL native, preserved unflipped):** for `left_x`/`right_x`,
/// negative = left, positive = right; for `left_y`/`right_y`, negative = up,
/// **positive = down** (SDL's documented thumbstick convention — this is *not*
/// screen/math Y-up). Content reading `left_y`/`right_y` must account for this.
///
/// SDL triggers report `0..32767` (never negative); dividing by 32767 gives `[0, 1]`
/// with `1.0` at full press. This is raw analog — no dead-zone, no discretization
/// (ADR 0040 §1 ⭐, §4: dead-zoning is the resolver's job, not the adapter's).
fn normalizeAxis(raw: i16, kind: AxisKind) f32 {
    const value: f32 = @floatFromInt(raw);
    return switch (kind) {
        .stick => if (raw < 0) value / 32768.0 else value / 32767.0,
        .trigger => value / 32767.0,
    };
}

/// Errors from bringing an OS window up. `SdlInit`/`SdlCreateWindow` carry no detail
/// here (SDL keeps the message in `SDL_GetError`); the allocator error is for the
/// null-terminated title copy SDL requires.
pub const OpenError = error{ SdlInit, SdlCreateWindow } || Allocator.Error;

/// Open the first currently-connected gamepad, if any (ADR 0040 §5: player 1 only, no
/// multi-pad routing — the first id SDL enumerates wins). `SDL_GetGamepads` allocates
/// the id array; it is freed here regardless of outcome. Returns `null` if no gamepad
/// is connected or the open call fails (both are ordinary "no pad" states, not errors —
/// the caller degrades to `pad_connected = false`).
fn openFirstGamepad() ?*c.SDL_Gamepad {
    var count: c_int = 0;
    const ids = c.SDL_GetGamepads(&count) orelse return null;
    defer c.SDL_free(ids);
    if (count == 0) return null;
    return c.SDL_OpenGamepad(ids[0]);
}

/// A real SDL3 OS window: presentation + input object for the interactive adapter
/// (ADR 0009 / 0012). `should_close` latches on the OS quit request (window close /
/// Cmd-Q) observed during `poll`; `poll` pumps the event queue then samples the
/// keyboard/mouse/gamepad; `surfaceHandle` yields the `SDL_Window*` for the `gpu`
/// port. Owns the OS window (freed by `close`); also owns the currently-open
/// `SDL_Gamepad*` handle, if any (closed by `close`); holds no allocator.
pub const Window = struct {
    handle: *c.SDL_Window,
    should_close: bool = false,
    /// The player-1 gamepad, opened by `open` (if one is already connected) or by
    /// `poll` on an `SDL_EVENT_GAMEPAD_ADDED` event. `null` when no gamepad is
    /// connected (ADR 0040 §5: one gamepad, player 1 only, in v1 — a second connected
    /// pad while one is already open is ignored, not queued). Closed by `close` and
    /// by `poll` on `SDL_EVENT_GAMEPAD_REMOVED` for this pad's instance id.
    pad: ?*c.SDL_Gamepad = null,

    /// Open an OS window sized by `config`. `gpa` allocates a null-terminated copy of
    /// `config.title` (SDL copies it internally, so the copy is freed before return);
    /// `config.title` is borrowed, not retained. Initializes SDL video **and gamepad**
    /// subsystems on first open (`SDL_INIT_GAMEPAD` implies `SDL_INIT_JOYSTICK`); `close`
    /// tears both back down. If a gamepad is already connected at open time, it is
    /// opened immediately (ADR 0040 §5, player 1 only) so the first `poll` after open
    /// already reports it — a pad plugged in later is picked up by `poll`'s
    /// `SDL_EVENT_GAMEPAD_ADDED` handling instead. Fails with `OpenError` if SDL init or
    /// window creation fails (see `SDL_GetError`).
    pub fn open(gpa: Allocator, config: port.WindowConfig) OpenError!Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD)) return error.SdlInit;
        errdefer c.SDL_Quit();

        const title_z = try gpa.dupeZ(u8, config.title);
        defer gpa.free(title_z);

        // `SDL_WINDOW_VULKAN` is required for `SDL_Vulkan_CreateSurface`, which the
        // `gpu` Vulkan backend calls to build its `VkSurfaceKHR` (ADR 0012 phase 2). It
        // also makes SDL load the Vulkan loader, so `SDL_Vulkan_GetInstanceExtensions`
        // works. Requested only when the Vulkan backend is compiled in (`enable_vulkan`),
        // so an SDL3-only (no-Vulkan) build opens a plain window unchanged. No Vulkan
        // type crosses this boundary — this is an SDL window flag, not a Vulkan handle.
        const vulkan_flag: u64 = if (build_options.enable_vulkan) c.SDL_WINDOW_VULKAN else 0;
        const flags: u64 = vulkan_flag | (if (config.resizable) c.SDL_WINDOW_RESIZABLE else 0);
        const handle = c.SDL_CreateWindow(
            title_z.ptr,
            @intCast(config.width),
            @intCast(config.height),
            flags,
        ) orelse return error.SdlCreateWindow;

        var win = Window{ .handle = handle };
        win.pad = openFirstGamepad();
        return win;
    }

    /// Destroy the OS window, close the tracked gamepad (if any), and shut SDL video +
    /// gamepad subsystems back down (symmetric with `open`).
    pub fn close(self: *Window) void {
        if (self.pad) |pad| c.SDL_CloseGamepad(pad);
        c.SDL_DestroyWindow(self.handle);
        c.SDL_Quit();
    }

    /// Whether the loop should exit — true once the OS requested the window close
    /// (observed by a prior `poll`).
    pub fn shouldClose(self: *const Window) bool {
        return self.should_close;
    }

    /// Set the OS window title (e.g. a live FPS/tick readout). `title` is borrowed for
    /// the call — SDL copies it — and must be NUL-terminated.
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.handle, title.ptr);
    }

    /// Sample this frame's input (ADR 0009: once per tick, immutable for the tick).
    /// Drains the SDL event queue first — latching the quit request, accumulating this
    /// frame's wheel delta, and opening/closing the tracked gamepad on
    /// connect/disconnect (ADR 0040 §5: `pad_connected` is a polled level flag, not an
    /// edge event — connect/disconnect are handled here only to keep `self.pad` current,
    /// never surfaced to `InputSnapshot` as their own event) — then reads the current
    /// keyboard, mouse, and gamepad state.
    pub fn poll(self: *Window) port.InputSnapshot {
        var snap = port.InputSnapshot{};

        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => self.should_close = true,
                c.SDL_EVENT_MOUSE_WHEEL => snap.wheel += ev.wheel.y,
                c.SDL_EVENT_GAMEPAD_ADDED => {
                    // Player 1 only (ADR 0040 §5): ignore a newly-added pad if one is
                    // already open.
                    if (self.pad == null) self.pad = c.SDL_OpenGamepad(ev.gdevice.which);
                },
                c.SDL_EVENT_GAMEPAD_REMOVED => {
                    if (self.pad) |pad| {
                        if (c.SDL_GetGamepadID(pad) == ev.gdevice.which) {
                            c.SDL_CloseGamepad(pad);
                            self.pad = null;
                        }
                    }
                },
                else => {},
            }
        }

        const kb = c.SDL_GetKeyboardState(null);
        inline for (key_map) |m| {
            if (kb[m.scancode]) snap.keys.insert(m.key);
        }

        var mx: f32 = 0;
        var my: f32 = 0;
        const buttons = c.SDL_GetMouseState(&mx, &my);
        snap.mouse = .{ mx, my };
        snap.mouse_buttons = .{
            .left = (buttons & buttonMask(c.SDL_BUTTON_LEFT)) != 0,
            .right = (buttons & buttonMask(c.SDL_BUTTON_RIGHT)) != 0,
            .middle = (buttons & buttonMask(c.SDL_BUTTON_MIDDLE)) != 0,
        };

        if (self.pad) |pad| {
            if (c.SDL_GamepadConnected(pad)) {
                snap.pad_connected = true;
                inline for (gamepad_button_map) |m| {
                    if (c.SDL_GetGamepadButton(pad, m.sdl)) snap.pad_buttons.insert(m.button);
                }
                inline for (gamepad_axis_map) |m| {
                    const raw = c.SDL_GetGamepadAxis(pad, m.sdl);
                    snap.pad_axes.set(m.axis, normalizeAxis(raw, m.kind));
                }
            }
        }
        return snap;
    }

    /// Current drawable size in pixels (queried live, so it tracks OS resizes).
    pub fn size(self: *const Window) [2]u32 {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        return .{ @intCast(w), @intCast(h) };
    }

    /// Request an OS resize of the window's drawable (feeds the gpu swapchain resize
    /// path, phase 2). Best-effort; SDL may clamp to display constraints.
    pub fn resize(self: *Window, width: u32, height: u32) void {
        _ = c.SDL_SetWindowSize(self.handle, @intCast(width), @intCast(height));
    }

    /// The opaque native surface handle for the `gpu` port: the `SDL_Window*` as
    /// `?*anyopaque`. `gpu` (not `platform`) turns this into a `VkSurfaceKHR` via
    /// `SDL_Vulkan_CreateSurface` (phase 2), so no Vulkan type crosses this boundary
    /// (CLAUDE.md #4). Lifetime: valid while the `Window` is open.
    pub fn surfaceHandle(self: *const Window) ?*anyopaque {
        return @ptrCast(self.handle);
    }
};

const testing = std.testing;

test "sdl3 key map covers every port.Key" {
    // Every engine key must map to a scancode, or `poll` would silently never report
    // it — this guards the arrow keys Snake needs against a future Key addition.
    inline for (std.meta.fields(port.Key)) |f| {
        const key = @field(port.Key, f.name);
        var found = false;
        for (key_map) |m| {
            if (m.key == key) found = true;
        }
        try testing.expect(found);
    }
}

test "sdl3 button masks match SDL button numbering" {
    try testing.expectEqual(@as(u32, 1), buttonMask(c.SDL_BUTTON_LEFT));
    try testing.expectEqual(@as(u32, 2), buttonMask(c.SDL_BUTTON_MIDDLE));
    try testing.expectEqual(@as(u32, 4), buttonMask(c.SDL_BUTTON_RIGHT));
}

test "sdl3 gamepad button map covers every port.GamepadButton" {
    // Mirrors the key_map coverage test: a newly-added GamepadButton must be mapped or
    // `poll` would silently never report it.
    inline for (std.meta.fields(port.GamepadButton)) |f| {
        const button = @field(port.GamepadButton, f.name);
        var found = false;
        for (gamepad_button_map) |m| {
            if (m.button == button) found = true;
        }
        try testing.expect(found);
    }
}

test "sdl3 gamepad axis map covers every port.GamepadAxis" {
    inline for (std.meta.fields(port.GamepadAxis)) |f| {
        const axis = @field(port.GamepadAxis, f.name);
        var found = false;
        for (gamepad_axis_map) |m| {
            if (m.axis == axis) found = true;
        }
        try testing.expect(found);
    }
}

test "sdl3 normalizeAxis: stick endpoints hit exactly [-1, 1], center is 0" {
    try testing.expectEqual(@as(f32, -1.0), normalizeAxis(-32768, .stick));
    try testing.expectEqual(@as(f32, 1.0), normalizeAxis(32767, .stick));
    try testing.expectEqual(@as(f32, 0.0), normalizeAxis(0, .stick));
}

test "sdl3 normalizeAxis: trigger endpoints hit exactly [0, 1]" {
    try testing.expectEqual(@as(f32, 0.0), normalizeAxis(0, .trigger));
    try testing.expectEqual(@as(f32, 1.0), normalizeAxis(32767, .trigger));
}

test "sdl3 window: open, size, surface handle, poll, close (dummy video driver)" {
    // The `dummy` video driver lets the full adapter path run with no display, so this
    // is a real end-to-end smoke test in CI: open a window, read its size + native
    // handle, poll once (no focus ⇒ empty snapshot), close. Skips if an image lacks
    // even the dummy driver rather than failing a windowless gate.
    if (!c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "dummy")) return error.SdlSetHint;
    var win = Window.open(testing.allocator, .{ .title = "smoke", .width = 320, .height = 240 }) catch {
        return error.SkipZigTest;
    };
    defer win.close();

    try testing.expect(!win.shouldClose());
    try testing.expect(win.surfaceHandle() != null);
    try testing.expectEqual([2]u32{ 320, 240 }, win.size());

    const snap = win.poll();
    try testing.expectEqual(@as(usize, 0), snap.keys.count());
    try testing.expectEqual(@as(f32, 0), snap.wheel);
}
