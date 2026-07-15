//! Headless main-menu/settings acceptance (issue #135; ADR 0034 UI subsystem, ADR
//! 0039 UI input events): drives the REAL `games/menu` content — its two `ui.Screen`
//! widget trees and `scripts/rules.lua` handler table — through the exact
//! `ui_dispatch.UiInput` / `script_runtime.Runtime` primitives #196 shipped, against a
//! real Lua interpreter, no window: navigate (arrow-key focus nav) → focus (`on_focus`
//! fires on each transition) → activate (`on_activate` fires on `Focus.current`,
//! mutating settings held as plain Lua state) → the resulting values persist to a ZON
//! file via the new `data.zon.saveFile` engine primitive (issue #135) → reload proves
//! the round trip. Lives in `tests/` because it reads the game corpus (`src/**` may
//! not) and needs `-Denable-lua` for the real handler table `on_activate` mutates.
//!
//! No `Sim`/`src/runtime/main.zig` wiring exists yet to route real input through
//! `UiInput` in the interactive `--play` loop (today only the display-only `hud`
//! screen is runner-wired, via `manifest.hud`) — see `games/menu/README.md`. This test
//! is the headless proof the content + dispatch + persistence primitives work
//! end-to-end; it does not claim the menu is playable in a window yet.

const std = @import("std");
const data = @import("data");
const core = @import("core");
const engine = @import("engine");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Skip unless the Lua backend is compiled in — `games/menu` declares `script_api = 1`
/// and its `on_activate` handler must actually run to mutate settings.
fn requireLua() !void {
    if (engine.script_api_version == 0) return error.SkipZigTest;
}

fn readFile(gpa: Allocator, io: Io, rel: []const u8) ![:0]u8 {
    return Io.Dir.cwd().readFileAllocOptions(io, rel, gpa, .unlimited, .of(u8), 0);
}

/// The shape `games/menu/save/settings.zon` persists — content-specific, so it lives
/// here (a `tests/` file, never `src/**`), not as a compiled type the package ships.
const Difficulty = enum { easy, normal, hard };
const Settings = struct {
    volume: u8 = 7,
    difficulty: Difficulty = .normal,
};

fn difficultyFromInt(v: i64) Difficulty {
    return switch (v) {
        1 => .easy,
        3 => .hard,
        else => .normal,
    };
}

test "menu acceptance: navigate -> focus -> activate -> settings change -> persists to ZON -> reloads" {
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The real content — human-editable ZON/Lua, the source of truth.
    const main_src = try readFile(gpa, io, "games/menu/screens/main_menu.zon");
    defer gpa.free(main_src);
    const main_menu = try engine.ui.parse(gpa, main_src);
    defer engine.ui.free(gpa, main_menu);

    const settings_src = try readFile(gpa, io, "games/menu/screens/settings.zon");
    defer gpa.free(settings_src);
    const settings_screen = try engine.ui.parse(gpa, settings_src);
    defer engine.ui.free(gpa, settings_screen);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);

    // The shipped default — read-only; the Lua defaults above must agree with it.
    const default_settings = try data.loadFile(Settings, gpa, io, Io.Dir.cwd(), "games/menu/save/settings.zon");
    try std.testing.expectEqual(@as(u8, 7), default_settings.volume);
    try std.testing.expectEqual(Difficulty.normal, default_settings.difficulty);

    var world = engine.World.init(gpa);
    defer world.deinit();
    var commands: engine.command.CommandBuffer = .{};
    defer commands.deinit(gpa);
    var timers: engine.Timers = .{};
    defer timers.deinit(gpa);
    var rng: core.Rng = core.Rng.init(0);
    const dc: engine.script_runtime.DispatchCtx = .{
        .world = &world,
        .commands = &commands,
        .gpa = gpa,
        .now_seconds = 0,
        .timers = &timers,
        .rng = &rng,
    };

    var rt: engine.script_runtime.Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, rules_src);

    var input: engine.ui_dispatch.UiInput = .{};
    const viewport: engine.ui.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    input.setScreen(&main_menu, viewport);

    // NAVIGATE + FOCUS: down bootstraps focus onto the first button, down again moves
    // to "settings_button" — each transition fires on_focus.
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expectEqual(&main_menu.root.children[1], input.focus.current.?);
    try std.testing.expectEqual(@as(i64, 2), rt.handlerFieldInt("focuses").?);

    // ACTIVATE: enter fires on_activate on the focused "settings_button".
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .enter, true));
    try std.testing.expectEqual(@as(i64, 2), rt.handlerFieldInt("next_screen").?);

    // A click on a hit widget also fires on_click (ADR 0039 §1), regardless of focus.
    try std.testing.expect(try input.pointerPress(gpa, &rt, dc, 60, 40));
    try std.testing.expectEqual(@as(i64, 1), rt.handlerFieldInt("clicks").?);

    // The driver reacts to next_screen: swap the active screen to "settings".
    input.setScreen(&settings_screen, viewport);

    // SETTINGS VALUE CHANGES: bootstrap focus onto "volume_up", activate it 5 times —
    // clamped at 10 (issue #135's requirement: activation changes a settings value).
    // From 7, three activations reach the ceiling (10); the last two clamp there.
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expectEqual(&settings_screen.root.children[0], input.focus.current.?);
    for (0..5) |_| try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .enter, true));
    try std.testing.expectEqual(@as(i64, 10), rt.handlerFieldInt("volume").?);

    // Move to "volume_down" and drop it back by one.
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expectEqual(&settings_screen.root.children[1], input.focus.current.?);
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .enter, true));
    try std.testing.expectEqual(@as(i64, 9), rt.handlerFieldInt("volume").?);

    // Move to "difficulty_cycle" and cycle it once: normal(2) -> hard(3).
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expectEqual(&settings_screen.root.children[2], input.focus.current.?);
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .enter, true));
    try std.testing.expectEqual(@as(i64, 3), rt.handlerFieldInt("difficulty").?);

    // PERSISTS TO ZON: the driver snapshots the handler table's settings fields and
    // saves them — to a temp path, never the shipped `save/settings.zon`.
    const edited: Settings = .{
        .volume = @intCast(rt.handlerFieldInt("volume").?),
        .difficulty = difficultyFromInt(rt.handlerFieldInt("difficulty").?),
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try data.saveFile(gpa, io, tmp.dir, "settings.zon", edited);

    // RELOADS: parsing the just-written file back reproduces the edited values
    // exactly, and they differ from the shipped default — proving this was a real
    // round trip of the session's edits, not a no-op.
    const reloaded = try data.loadFile(Settings, gpa, io, tmp.dir, "settings.zon");
    try std.testing.expectEqualDeep(edited, reloaded);
    try std.testing.expectEqual(@as(u8, 9), reloaded.volume);
    try std.testing.expectEqual(Difficulty.hard, reloaded.difficulty);
    try std.testing.expect(reloaded.volume != default_settings.volume);
}
