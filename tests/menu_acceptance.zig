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
//! `Sim.ui_input` + `runtime/main.zig`'s `--play` loop now route real keyboard input
//! into this exact `UiInput` (issue #209: `games/menu/game.zon`'s `.hud` doubles as
//! the active `UiInput` screen) — see `games/menu/README.md` for the remaining gaps
//! (no focus highlight, no screen-switching, no pointer routing). This test remains
//! the headless proof the content + dispatch + persistence primitives work
//! end-to-end, including the settings-screen swap a real `--play` session does not
//! yet drive automatically.
//!
//! Since #239 it also carries the **controls-screen remap staircase** (ADR 0041 §5) —
//! `games/menu`'s `input.zon` + `screens/controls.zon` + `scripts/rules.lua` driven
//! through a real `Sim`, proving capture → validate → record → persist → reload →
//! live-swap end-to-end. See the section header below.

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

// --- Controls screen: the in-game remap chain (ADR 0041 §5, issue #239) -------------
//
// The payoff of ADR 0041's five phases, driven against the REAL `games/menu` content
// (`input.zon` + `screens/controls.zon` + `scripts/rules.lua`) through a REAL `Sim` —
// the same object `--play` ticks, routing the same key/pad edges into the same
// `ui_input` and the same action resolver. What a windowed session adds on top is a
// window, a file watcher, and a `main` loop; every link below is the shipped one.

const platform = engine.platform;
const Key = platform.Key;
const GamepadButton = platform.GamepadButton;

/// The `Sim` a `--play` session of `games/menu` runs, minus the window: the package
/// action map borrowed onto `action_map`, the controls screen active in `ui_input`, and
/// `scripts/rules.lua` loaded as the handler table. `screen`/`map` are borrowed — the
/// caller owns them and must outlive the `Sim` (exactly the runner's ownership).
fn controlsSim(sim: *engine.Sim, rules_src: [:0]const u8, screen: *const engine.ui.Screen, map: *const engine.ActionMap) !void {
    try sim.loadScript(rules_src);
    sim.ui_input.setScreen(screen, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    sim.action_map = map;
}

/// Tick one press edge of `key` and then its release, as a real session does: a key is
/// held for a frame and let go. The press is the only qualifying capture edge (ADR 0041
/// §1.1); the release falls through, exercising that it binds nothing.
fn tapKey(sim: *engine.Sim, key: Key) !void {
    var snap: platform.InputSnapshot = .{};
    snap.keys.insert(key);
    sim.setInput(snap);
    try sim.tick();
    sim.setInput(.{});
    try sim.tick();
}

/// `tapKey`'s gamepad-button twin — the other digital edge stream capture qualifies.
fn tapPad(sim: *engine.Sim, button: GamepadButton) !void {
    var snap: platform.InputSnapshot = .{};
    snap.pad_buttons.insert(button);
    sim.setInput(snap);
    try sim.tick();
    sim.setInput(.{});
    try sim.tick();
}

/// How many times `scripts/rules.lua`'s `on_action` has seen `action` fire — the
/// package's only observable that an action fired at all, and so the proof that a
/// rebound input really drives the action (and the old one no longer does).
fn firedCount(sim: *engine.Sim, comptime action: []const u8) i64 {
    return sim.script_runtime.handlerFieldInt("fired_" ++ action) orelse 0;
}

/// The player override `bindings` handler field as the persistence driver reads it: the
/// source recorded for `action`, or null when the player never rebound it. The result is
/// `gpa`-owned; free it.
fn recordedBinding(gpa: Allocator, sim: *engine.Sim, action: []const u8) !?[]const u8 {
    const pairs = try sim.script_runtime.handlerFieldStrMap(gpa, "bindings") orelse return null;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, pairs);
    for (pairs) |p| {
        if (std.mem.eql(u8, p.key, action)) return try gpa.dupe(u8, p.value);
    }
    return null;
}

/// Re-resolve the effective map the way `runtime`'s watcher does on a change to either
/// file (ADR 0041 §3): re-parse the override that was just written and merge it over the
/// package map. The caller owns the result (`engine.action_map.free`) and swaps
/// `sim.action_map` to it — `ActionMapState.reload` is the runner's private owner of
/// exactly this pair of steps.
fn reloadEffective(gpa: Allocator, io: Io, dir: Io.Dir, pkg_map: engine.ActionMap) !engine.ActionMap {
    const src = try dir.readFileAllocOptions(io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const override = try engine.action_map.parse(gpa, src);
    defer engine.action_map.free(gpa, override);
    return engine.action_map.merge(gpa, pkg_map, override);
}

test "menu controls: rules.lua's mirrored default bindings agree with the package input.zon, in BOTH source vocabularies" {
    // The one drift risk the remap content carries: a script cannot read `input.zon`
    // (ADR 0003 §7 removed io/os), and the engine seeds it only with the user OVERRIDE
    // (#247), never the package defaults — so `rules.lua` MIRRORS those defaults to
    // validate duplicates for the actions the player never rebound. The file is the
    // source of truth; this test is what keeps the mirror honest.
    //
    // It asserts EVERY shipped source — key and pad button — because the duplicate check
    // is only as complete as the mirror, and a mirror hole is invisible from the remap
    // flow itself: an unmirrored source is simply never recognised as taken, so the
    // rebind is accepted and the collision only surfaces later, in-game, as one press
    // firing two actions. An earlier revision of this test checked `keys` alone and
    // shipped exactly that bug.
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const input_src = try readFile(gpa, io, "games/menu/input.zon");
    defer gpa.free(input_src);
    const pkg_map = try engine.action_map.parse(gpa, input_src);
    defer engine.action_map.free(gpa, pkg_map);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);
    var rt: engine.script_runtime.Runtime = .{};
    defer rt.deinit(gpa);
    try rt.loadHandlers(gpa, rules_src);

    const mirrored_keys = try rt.handlerFieldStrMap(gpa, "default_bindings") orelse return error.TestUnexpectedResult;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, mirrored_keys);
    try std.testing.expectEqual(pkg_map.bindings.len, mirrored_keys.len);
    for (mirrored_keys) |p| {
        const action = pkg_map.find(p.key) orelse return error.TestUnexpectedResult;
        // Every rebindable action is a digital `button` (v1 capture defers analog, ADR
        // 0041 §1.1), and the mirror names its default KEY in the capture vocabulary:
        // a bare `@tagName`, no prefix.
        try std.testing.expectEqual(engine.action_map.ActionType.button, action.type);
        try std.testing.expectEqual(@as(usize, 1), action.keys.len);
        try std.testing.expectEqualStrings(@tagName(action.keys[0]), p.value);
    }

    // The pad half of the same mirror: capture reports a button `pad_`-prefixed (ADR
    // 0041 §1.1), so that is how `rules.lua` must hold it — and `input.zon` holds the
    // bare enum literal. This asserts the prefixed round trip of every shipped button.
    const mirrored_pads = try rt.handlerFieldStrMap(gpa, "default_pad_bindings") orelse return error.TestUnexpectedResult;
    defer engine.script_runtime.Runtime.freeStrMap(gpa, mirrored_pads);
    try std.testing.expectEqual(pkg_map.bindings.len, mirrored_pads.len);
    for (mirrored_pads) |p| {
        const action = pkg_map.find(p.key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), action.pad_buttons.len);
        var buf: [32]u8 = undefined;
        const prefixed = try std.fmt.bufPrint(&buf, "pad_{s}", .{@tagName(action.pad_buttons[0])});
        try std.testing.expectEqualStrings(prefixed, p.value);
    }
}

test "menu controls acceptance: capture -> validate -> record -> persist -> reload -> live-swap" {
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The real content — human-editable ZON/Lua, the source of truth.
    const input_src = try readFile(gpa, io, "games/menu/input.zon");
    defer gpa.free(input_src);
    const pkg_map = try engine.action_map.parse(gpa, input_src);
    defer engine.action_map.free(gpa, pkg_map);

    const controls_src = try readFile(gpa, io, "games/menu/screens/controls.zon");
    defer gpa.free(controls_src);
    const controls = try engine.ui.parse(gpa, controls_src);
    defer engine.ui.free(gpa, controls);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);

    // The override lands in a temp dir, never the shipped `games/menu/save/`: a test
    // must not write into git-tracked content.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var owned_effective: ?engine.ActionMap = null;
    defer if (owned_effective) |m| engine.action_map.free(gpa, m);

    var sim = engine.Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    try controlsSim(&sim, rules_src, &controls, &pkg_map);

    // Seeded before any rebind, exactly as `runPlay` seeds it right after loading the
    // script: whatever revision the script starts at counts as already persisted.
    var writer: engine.input_override.OverrideWriter = .init(&sim.script_runtime);
    const Outcome = engine.input_override.Outcome;

    // 1. BASELINE — the package default is live: W fires `fire` (input.zon's binding).
    try tapKey(&sim, .w);
    try std.testing.expectEqual(@as(i64, 1), firedCount(&sim, "fire"));

    // 2. ARM — focus the FIRE row and activate it: on_activate calls mana.capture_input.
    try tapKey(&sim, .down); // bootstraps focus onto the first row, "rebind_fire"
    try std.testing.expectEqual(&controls.root.children[0], sim.ui_input.focus.current.?);
    try tapKey(&sim, .enter);
    try std.testing.expectEqualStrings("fire", sim.script_runtime.armedCapture().?);

    // 3. REJECT (reserved) — escape is the menu's own back/cancel key: captured, not
    // recorded, and nothing is persisted because the revision never moves.
    try tapKey(&sim, .escape);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("rejected_bindings").?);
    try std.testing.expect(sim.script_runtime.armedCapture() == null); // one-shot: delivery disarmed
    try std.testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "input.zon", .{}));

    // 4. REJECT (duplicate) — A already fires `interact`; binding it to `fire` too would
    // make one press fire both.
    try tapKey(&sim, .enter); // re-arm the still-focused FIRE row
    try tapKey(&sim, .a);
    try std.testing.expectEqual(@as(i64, 2), sim.script_runtime.handlerFieldInt("rejected_bindings").?);
    try std.testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
    try std.testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    // KNOWN ENGINE GAP, pinned here deliberately (do not "correct" this expectation):
    // ADR 0041 §1 says a captured edge "does not reach gameplay `on_action`/`on_key`",
    // and `Sim.tick` honours that for `on_key` (it skips dispatch when `ui_input` claimed
    // the edge, src/engine/sim.zig:322) but NOT for `on_action`: the action-edge loop
    // (`:352`) diffs the raw snapshot unconditionally, never consulting capture. So
    // pressing A while capture is armed fires `interact` at gameplay anyway. Harmless in
    // this package (a menu with no gameplay), real for a game remapping mid-play.
    // Closing it is engine work in `sim.zig`; content cannot, and must not, work around
    // it. This assertion is the honest record — it goes red when the gap is closed.
    try std.testing.expectEqual(@as(i64, 1), firedCount(&sim, "interact"));

    // 5. ACCEPT + RECORD — D is free: the script records it and bumps the revision.
    try tapKey(&sim, .enter);
    try tapKey(&sim, .d);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
    const recorded = (try recordedBinding(gpa, &sim, "fire")).?;
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings("d", recorded); // the capture vocabulary, verbatim

    // 6. PERSIST — the driver reads those exact fields and writes the override file.
    try std.testing.expectEqual(Outcome{ .written = 1 }, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));

    // 7. RELOAD + LIVE-SWAP — re-parse the override, re-merge over the package map, and
    // swap the borrow at a tick boundary (ADR 0041 §3). Nothing else about the session
    // changes: same Sim, same script state, same screen.
    owned_effective = try reloadEffective(gpa, io, tmp.dir, pkg_map);
    sim.action_map = &owned_effective.?;

    // 8. APPLIED — D now fires `fire`; W (the package default) no longer does, because
    // an override REPLACES the action's whole binding (per-action replace, ADR 0041 §2).
    try tapKey(&sim, .d);
    try std.testing.expectEqual(@as(i64, 2), firedCount(&sim, "fire"));
    try tapKey(&sim, .w);
    try std.testing.expectEqual(@as(i64, 2), firedCount(&sim, "fire"));
    // An action absent from the override still resolves to its package default: A fires
    // `interact` across the swap (2 = this press, plus the one step 4's gap leaked).
    try tapKey(&sim, .a);
    try std.testing.expectEqual(@as(i64, 2), firedCount(&sim, "interact"));
}

test "menu controls acceptance: a captured PAD BUTTON persists and applies through the same chain" {
    // The `source` vocabulary is asymmetric (ADR 0041 §1.1): keys arrive bare ("d"), pad
    // buttons `pad_`-prefixed ("pad_south"). Content passes both through untouched and
    // the driver routes them; this is the leg that proves the pad half of that contract
    // end-to-end, from a real pad edge to a live rebound action.
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const input_src = try readFile(gpa, io, "games/menu/input.zon");
    defer gpa.free(input_src);
    const pkg_map = try engine.action_map.parse(gpa, input_src);
    defer engine.action_map.free(gpa, pkg_map);

    const controls_src = try readFile(gpa, io, "games/menu/screens/controls.zon");
    defer gpa.free(controls_src);
    const controls = try engine.ui.parse(gpa, controls_src);
    defer engine.ui.free(gpa, controls);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var owned_effective: ?engine.ActionMap = null;
    defer if (owned_effective) |m| engine.action_map.free(gpa, m);

    var sim = engine.Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    try controlsSim(&sim, rules_src, &controls, &pkg_map);
    var writer: engine.input_override.OverrideWriter = .init(&sim.script_runtime);
    const Outcome = engine.input_override.Outcome;

    // Focus the PAUSE row (third) and arm it, then press a pad button — the pad edge
    // stream `padButtonEdge` claims while capture is armed.
    for (0..3) |_| try tapKey(&sim, .down);
    try std.testing.expectEqual(&controls.root.children[2], sim.ui_input.focus.current.?);
    try tapKey(&sim, .enter);

    // REJECT (pad duplicate) — NORTH is `interact`'s shipped pad button. The duplicate
    // rule is per-source, not per-device: accepting this would make one press fire both
    // `pause` and `interact` after the swap, which is exactly what a duplicate check is
    // for. This case shipped broken once (the mirror listed key defaults only, so no pad
    // source was ever seen as taken) — hence a behavioral assertion, not just the mirror
    // one above.
    try tapPad(&sim, .north);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("rejected_bindings").?);
    try std.testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
    try std.testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "input.zon", .{}));

    // ACCEPT — SOUTH is bound to nothing, so it is a legitimate rebind.
    try tapKey(&sim, .enter); // re-arm the still-focused PAUSE row
    try tapPad(&sim, .south);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("accepted_bindings").?);

    const recorded = (try recordedBinding(gpa, &sim, "pause")).?;
    defer gpa.free(recorded);
    try std.testing.expectEqualStrings("pad_south", recorded); // prefixed, un-translated

    try std.testing.expectEqual(Outcome{ .written = 1 }, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    owned_effective = try reloadEffective(gpa, io, tmp.dir, pkg_map);
    sim.action_map = &owned_effective.?;

    // The driver stripped `pad_` and routed it into `pad_buttons`: the SOUTH button now
    // fires `pause`, and neither its package key (S) nor its package pad button (START)
    // does — per-action replace again, across the device boundary.
    try tapPad(&sim, .south);
    try std.testing.expectEqual(@as(i64, 1), firedCount(&sim, "pause"));
    try tapKey(&sim, .s);
    try tapPad(&sim, .start);
    try std.testing.expectEqual(@as(i64, 1), firedCount(&sim, "pause"));
}

test "menu controls acceptance: SESSION 2 keeps session 1's rebind, and validates against it (#247)" {
    // The cross-session leg — structurally invisible to every test above, which all live
    // inside one session. Two `Sim` lifetimes over ONE override file, with the second
    // seeded from that file exactly as `playLoop` seeds it after loading the script
    // (`syncScriptBindings`). It pins BOTH halves of #247:
    //   1. the whole-override write tells the truth (session 1's `fire` is not dropped);
    //   2. `rules.lua`'s duplicate check sees session 1's LIVE bindings, not the shipped
    //      defaults it mirrors — in BOTH source vocabularies (a bare key, a `pad_`-prefixed
    //      button), since a seed spelled in the wrong one would silently stop matching.
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const input_src = try readFile(gpa, io, "games/menu/input.zon");
    defer gpa.free(input_src);
    const pkg_map = try engine.action_map.parse(gpa, input_src);
    defer engine.action_map.free(gpa, pkg_map);

    const controls_src = try readFile(gpa, io, "games/menu/screens/controls.zon");
    defer gpa.free(controls_src);
    const controls = try engine.ui.parse(gpa, controls_src);
    defer engine.ui.free(gpa, controls);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Outcome = engine.input_override.Outcome;

    // --- SESSION 1: rebind `fire` (default W) to D and `pause` (default pad START) to pad
    // SOUTH — one of each vocabulary — then persist and quit. ---------------------------
    {
        var sim = engine.Sim.init(gpa, 1.0 / 60.0);
        defer sim.deinit();
        try controlsSim(&sim, rules_src, &controls, &pkg_map);
        var writer: engine.input_override.OverrideWriter = .init(&sim.script_runtime);

        try tapKey(&sim, .down); // focus "rebind_fire"
        try tapKey(&sim, .enter); // arm
        try tapKey(&sim, .d);
        for (0..2) |_| try tapKey(&sim, .down); // focus "rebind_pause"
        try tapKey(&sim, .enter);
        try tapPad(&sim, .south);
        try std.testing.expectEqual(@as(i64, 2), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
        try std.testing.expectEqual(Outcome{ .written = 2 }, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    }

    // --- SESSION 2: a fresh Sim + interpreter, the same file. --------------------------
    var owned_effective = try reloadEffective(gpa, io, tmp.dir, pkg_map); // the startup merge
    defer engine.action_map.free(gpa, owned_effective);

    var sim = engine.Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    try controlsSim(&sim, rules_src, &controls, &owned_effective);

    // THE SEAM: hand the fresh script the override that is on disk. Without this line
    // `bindings` is empty and both assertions below fail — the bug #247 reports.
    const override_src = try tmp.dir.readFileAllocOptions(io, "input.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(override_src);
    const override = try engine.action_map.parse(gpa, override_src);
    defer engine.action_map.free(gpa, override);
    const seed = try engine.input_override.seedBindings(gpa, &sim.script_runtime, override);
    defer gpa.free(seed.skipped);
    try std.testing.expectEqual(@as(usize, 0), seed.skipped.len); // every capture-written entry round-trips

    var writer: engine.input_override.OverrideWriter = .init(&sim.script_runtime);
    // The seed is not a proposal: a session that rebinds nothing rewrites nothing.
    try std.testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));
    // Both of session 1's rebinds are back in the script, each in the vocabulary the
    // script itself emits: a key bare, a pad button `pad_`-prefixed (ADR 0041 §1.1).
    const seeded_key = (try recordedBinding(gpa, &sim, "fire")).?;
    defer gpa.free(seeded_key);
    try std.testing.expectEqualStrings("d", seeded_key);
    const seeded_pad = (try recordedBinding(gpa, &sim, "pause")).?;
    defer gpa.free(seeded_pad);
    try std.testing.expectEqualStrings("pad_south", seeded_pad);

    // 1. VALIDATION — try to bind `interact` to D as well. `rules.lua` mirrors the SHIPPED
    // default (`fire` = W), so only the seeded live binding can make this a duplicate.
    try tapKey(&sim, .down);
    try tapKey(&sim, .down); // focus "rebind_interact" (the second row)
    try std.testing.expectEqual(&controls.root.children[1], sim.ui_input.focus.current.?);
    try tapKey(&sim, .enter);
    try tapKey(&sim, .d);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("rejected_bindings").?);
    try std.testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
    try std.testing.expectEqual(Outcome.unchanged, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));

    // 2. VALIDATION, the PAD half — try to bind `interact` to pad SOUTH, which session 1
    // gave to `pause`. Nothing in `rules.lua`'s shipped mirror knows SOUTH is taken; only
    // the seeded live binding does, and only if it kept its `pad_` prefix across the trip.
    // Seed it as bare `"south"` and this comparison silently stops matching — the exact
    // half-a-vocabulary hole that shipped a broken duplicate check here once before.
    try tapKey(&sim, .enter); // re-arm the still-focused interact row
    try tapPad(&sim, .south);
    try std.testing.expectEqual(@as(i64, 2), sim.script_runtime.handlerFieldInt("rejected_bindings").?);
    try std.testing.expectEqual(@as(i64, 0), sim.script_runtime.handlerFieldInt("accepted_bindings").?);

    // 3. VALIDATION, the other way — bind `interact` to W. W is `fire`'s SHIPPED default,
    // so the mirror alone says "taken"; only the seeded live binding (fire = D) frees it.
    // This assertion fails in the opposite direction from the one above: un-seeded, the
    // script would REJECT a key nothing is actually bound to.
    try tapKey(&sim, .enter); // re-arm the still-focused interact row
    try tapKey(&sim, .w);
    try std.testing.expectEqual(@as(i64, 1), sim.script_runtime.handlerFieldInt("accepted_bindings").?);
    try std.testing.expectEqual(@as(i64, 2), sim.script_runtime.handlerFieldInt("rejected_bindings").?); // still just the two above

    // 4. PERSISTENCE — the write is the WHOLE override, so this is the exact moment
    // session 1's two rebinds would have been silently dropped.
    try std.testing.expectEqual(Outcome{ .written = 3 }, try writer.poll(gpa, io, tmp.dir, "input.zon", &sim.script_runtime));

    // BOTH sessions' rebinds are in the file — and all APPLY: re-merge and swap, then
    // drive each newly bound input. `fire` = D survived a session it was never rebound in.
    engine.action_map.free(gpa, owned_effective);
    owned_effective = try reloadEffective(gpa, io, tmp.dir, pkg_map);
    sim.action_map = &owned_effective;

    const before_fire = firedCount(&sim, "fire");
    const before_interact = firedCount(&sim, "interact");
    try tapKey(&sim, .d);
    try std.testing.expectEqual(before_fire + 1, firedCount(&sim, "fire"));
    try tapKey(&sim, .w);
    try std.testing.expectEqual(before_interact + 1, firedCount(&sim, "interact"));
    // W drives `interact` ONLY: per-action replace means it is no longer `fire`'s key
    // either, one session after `fire` moved off it.
    try std.testing.expectEqual(before_fire + 1, firedCount(&sim, "fire"));
    // And `interact`'s own package default is dead: A fires nothing at all now.
    try tapKey(&sim, .a);
    try std.testing.expectEqual(before_interact + 1, firedCount(&sim, "interact"));
    // The pad half survived the same round trip: SOUTH still fires `pause` a session
    // later, and `pause`'s package button (START) still does not.
    const before_pause = firedCount(&sim, "pause");
    try tapPad(&sim, .south);
    try std.testing.expectEqual(before_pause + 1, firedCount(&sim, "pause"));
    try tapPad(&sim, .start);
    try std.testing.expectEqual(before_pause + 1, firedCount(&sim, "pause"));
}

test "menu controls: a pointer click while capture is armed cancels it, so the next keypress binds nothing" {
    // The pointer is the one input capture does NOT claim (ADR 0041 §1 intercepts key
    // and pad-button edges), so a click is the player's other way out of "press a key…"
    // — and `mana.cancel_capture` is what makes it one. Driven through `UiInput` directly
    // because `Sim.tick` has no pointer routing yet (issue #209's gap).
    try requireLua();
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const controls_src = try readFile(gpa, io, "games/menu/screens/controls.zon");
    defer gpa.free(controls_src);
    const controls = try engine.ui.parse(gpa, controls_src);
    defer engine.ui.free(gpa, controls);

    const rules_src = try readFile(gpa, io, "games/menu/scripts/rules.lua");
    defer gpa.free(rules_src);

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
    input.setScreen(&controls, .{ .x = 0, .y = 0, .w = 400, .h = 300 });

    // Arm capture on the FIRE row.
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .enter, true));
    try std.testing.expectEqualStrings("fire", rt.armedCapture().?);

    // A click reaches on_click even while armed; rules.lua answers it with
    // mana.cancel_capture.
    try std.testing.expect(try input.pointerPress(gpa, &rt, dc, 60, 50));
    try std.testing.expect(rt.armedCapture() == null);

    // Disarmed for real: the next press drives focus nav again instead of binding, and
    // nothing was recorded or proposed for persistence.
    try std.testing.expect(try input.keyEdge(gpa, &rt, dc, .down, true));
    try std.testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("accepted_bindings").?);
    try std.testing.expectEqual(@as(i64, 0), rt.handlerFieldInt("bindings_revision").?);
}
