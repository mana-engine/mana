//! Data-driven acceptance staircase (ADR 0028 layer 2; issue #94): loads each real
//! game package's `scenarios/*.zon` files and replays them through the generic
//! `engine.scenario` referee — one Zig `test` per staircase step, so a red test names
//! exactly which mechanic broke, never just "the game broke". This generalizes the
//! Zig-side behavioral PoC ADR 0028 landed with (the original `tests/
//! acceptance_snake.zig`, a hand-written Snake-only staircase) into a single harness
//! any game's `scenarios/*.zon` drives — Pac-Man's staircase is now first-class here
//! too, exactly the format those scenario files declare, with zero genre knowledge
//! in this file (the `Package` loader is exactly `src/runtime/main.zig`'s load path,
//! reimplemented here because `tests/` cannot import the `runtime` executable as a
//! module; only the two packages' relative paths below are game-specific).
//!
//! Gated on `-Denable-lua`: both packages are pure Lua content (`rules.lua`), so
//! without the scripting backend every test here skips (`script_api_version == 0`).
//! Plain `mise run test`/`build` never passes that flag, so this file only ever
//! *compiled* there — `mise run test-lua` (wired into `mise run check`, issue #163)
//! is what actually executes the staircase.

const std = @import("std");
const core = @import("core");
const engine = @import("engine");

const Io = std.Io;
const Allocator = std.mem.Allocator;

fn readFile(gpa: Allocator, io: Io, rel: []const u8) ![:0]u8 {
    return Io.Dir.cwd().readFileAllocOptions(io, rel, gpa, .unlimited, .of(u8), 0);
}

/// Skip a test unless the Lua backend is compiled in. `script_api_version` is 0
/// without `-Denable-lua`, and every package here declares `script_api = 1`.
fn requireLua() !void {
    if (engine.script_api_version == 0) return error.SkipZigTest;
}

/// A game package's fixed file layout (relative to the build's cwd, like every
/// integration test that reads the game corpus — `src/**` may not).
const PackagePaths = struct {
    prototypes: []const u8,
    scene: []const u8,
    rules: []const u8,
};

const snake_paths: PackagePaths = .{
    .prototypes = "games/snake/prototypes.zon",
    .scene = "games/snake/scenes/board.zon",
    .rules = "games/snake/rules.lua",
};

const pacman_paths: PackagePaths = .{
    .prototypes = "games/pacman/prototypes.zon",
    .scene = "games/pacman/scenes/maze.zon",
    .rules = "games/pacman/rules.lua",
};

/// A loaded, ready-to-replay game package: prototypes → scene (+ tilemap, if any) →
/// Lua rules → enter scene → the engine's full standard system set, in the exact
/// order `src/runtime/main.zig`'s `registerStandardSystems` uses (`nav -> movement ->
/// collision -> regen`). Registering `nav`/`collision` unconditionally is a
/// genre-neutral no-op for Snake (no tilemap/agents/colliders) — see that function's
/// doc — so one load path serves both games. Heap-allocated so the borrowed
/// prototype/scene slices stay pinned; caller owns the result, call `deinit`.
const Package = struct {
    gpa: Allocator,
    proto_src: [:0]u8,
    proto_file: engine.prototype.File,
    scene_src: [:0]u8,
    scene: engine.Scene,
    rules: [:0]u8,
    sim: engine.Sim,

    fn load(gpa: Allocator, io: Io, paths: PackagePaths) !*Package {
        const self = try gpa.create(Package);
        errdefer gpa.destroy(self);
        self.gpa = gpa;

        self.proto_src = try readFile(gpa, io, paths.prototypes);
        errdefer gpa.free(self.proto_src);
        self.proto_file = try engine.prototype.parse(gpa, self.proto_src);
        errdefer engine.prototype.free(gpa, self.proto_file);

        self.scene_src = try readFile(gpa, io, paths.scene);
        errdefer gpa.free(self.scene_src);
        self.scene = try engine.scene.parse(gpa, self.scene_src);
        errdefer engine.scene.free(gpa, self.scene);

        self.rules = try readFile(gpa, io, paths.rules);
        errdefer gpa.free(self.rules);

        self.sim = engine.Sim.init(gpa, core.time.default_dt);
        errdefer self.sim.deinit();
        self.sim.prototypes = .{ .prototypes = self.proto_file.prototypes };
        try engine.scene.load(self.scene, &self.sim.world);
        if (self.scene.tilemap) |*tm| self.sim.tilemap = tm;
        try self.sim.loadScript(self.rules);
        self.sim.enterScene(self.scene.name);
        try self.sim.addSystem(engine.nav.navSystem);
        try self.sim.addSystem(engine.systems.movementSystem);
        try self.sim.addSystem(engine.collision.collisionSystem);
        try self.sim.addSystem(engine.systems.regenSystem);
        return self;
    }

    fn deinit(self: *Package) void {
        const gpa = self.gpa;
        self.sim.deinit();
        engine.prototype.free(gpa, self.proto_file);
        engine.scene.free(gpa, self.scene);
        gpa.free(self.proto_src);
        gpa.free(self.scene_src);
        gpa.free(self.rules);
        gpa.destroy(self);
    }
};

/// Load `paths`, replay `scenario_path` against it through `engine.scenario.run`, and
/// fail loudly — printing every failing assertion's label/detail plus any Layer-1
/// invariant violation — if the report is not all-green. This is exactly what
/// `--scenario` prints (`src/runtime/main.zig`'s `runScenario`), so a CI failure here
/// reads the same as running it by hand.
fn expectScenarioPasses(gpa: Allocator, io: Io, paths: PackagePaths, scenario_path: []const u8) !void {
    var pkg = try Package.load(gpa, io, paths);
    defer pkg.deinit();

    const src = try readFile(gpa, io, scenario_path);
    defer gpa.free(src);
    const scenario = try engine.scenario.parse(gpa, src);
    defer engine.scenario.free(gpa, scenario);

    var report = try engine.scenario.run(gpa, &pkg.sim, scenario);
    defer report.deinit();

    if (!report.passed()) {
        for (report.results.items) |r| {
            if (!r.passed) std.debug.print("FAIL [{s}] at tick {d}: {s}\n", .{ r.label, r.at_tick, r.detail });
        }
        if (report.invariant_violation) |iv| {
            std.debug.print("invariant violated at tick {d}: {f}\n", .{ iv.tick, iv.violation });
        }
        return error.ScenarioFailed;
    }
}

/// Two independent replays of the same scenario against fresh sims must agree
/// bit-for-bit (entity count and state hash) — proving the Lua-driven port of ADR
/// 0028's PoC stayed deterministic, the property the original `acceptance_snake.zig`
/// checked with a hand-written trace and this checks generically for any scenario.
fn expectDeterministic(gpa: Allocator, io: Io, paths: PackagePaths, scenario_path: []const u8) !void {
    const src = try readFile(gpa, io, scenario_path);
    defer gpa.free(src);
    const scenario = try engine.scenario.parse(gpa, src);
    defer engine.scenario.free(gpa, scenario);

    var a = try Package.load(gpa, io, paths);
    defer a.deinit();
    var b = try Package.load(gpa, io, paths);
    defer b.deinit();

    var ra = try engine.scenario.run(gpa, &a.sim, scenario);
    defer ra.deinit();
    var rb = try engine.scenario.run(gpa, &b.sim, scenario);
    defer rb.deinit();

    try std.testing.expect(ra.passed());
    try std.testing.expect(rb.passed());
    try std.testing.expectEqual(a.sim.world.count(), b.sim.world.count());
    try std.testing.expectEqual(a.sim.stateHash(), b.sim.stateHash());
}

// --- Snake staircase (games/snake/scenarios/*.zon): spawn -> advance -> turn -> eat
// -> grow -> death (ADR 0028's example order; issue #94 requires Snake first-class). --

test "snake scenario [spawn]: bootstrap places the head, one food, and the wall ring" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/01_spawn.zon");
}

test "snake scenario [advance]: with no input the head steps one cell per grid tick" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/02_advance.zon");
}

test "snake scenario [turn]: an on_key press turns the head off its default heading" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/03_turn.zon");
}

test "snake scenario [eat]: steering the head onto the food cell reaches it" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/04_eat.zon");
}

test "snake scenario [grow]: length increases by one after eating" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/05_grow.zon");
}

test "snake scenario [death]: running into the wall resets the run to the origin" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/06_death.zon");
}

test "snake scenario: two independent replays of the eat staircase agree bit-for-bit" {
    try requireLua();
    try expectDeterministic(std.testing.allocator, std.testing.io, snake_paths, "games/snake/scenarios/04_eat.zon");
}

// --- Pac-Man staircase (games/pacman/scenarios/*.zon): spawn -> move -> turn -> eats
// dot -> ghost collision -> frightened catch -> chase/scatter mode flip -> straight
// through an intersection, no auto-corner -- the analogous staircase issue #94 asks
// for, per what the native tilemap/nav/collision sim supports today (continuous
// steering, not a grid teleport; a ghost catch is a reset, not a kill). Steps 6/7 (Refs
// #62) exercise the fourth ghost and the four distinct classic targeting rules
// `rules.lua`'s `retarget` now applies by spawn index. Step 8 keeps pac holding a
// straight line through an intersection and stopping dead at a wall (no auto-corner):
// since #139 pac's nav target is the FARTHEST walkable cell along its heading (not the
// single next cell #108 used), a pure-axis target whose BFS shortest path is the straight
// line, so pac still cannot corner-cut — but it now moves at CONSTANT speed with no
// per-cell stall (the #139 stutter fix; the 1-cell-ahead target let pac reach its target
// between 0.1s retargets and stall flush on each cell centre). Rebased onto #128's
// tint/blink cues (fruit pickup added to maze.zon), the combined effect moved two
// checkpoints: step 4's dot-eat now checks at tick 37 (was 43) so it lands BEFORE pac —
// flowing continuously — reaches #128's fruit at world (-6,4) and eats it (score would
// jump to 110); pac sits on the dot cell (-5,4) there, so the locator value is unchanged.
// Step 6's score read is now 160 (dot 10 + fruit 100 + pellet 50) and its locator moved
// to (-8,4) (was -7.4), because #139 pac parks flush on the pellet cell by tick 65. Every
// other checkpoint — pac's parked cell, the ghost choreography, counts, ticks — is unchanged.
// Steps 3 and 8 split the two turn fundamentals cleanly (ADR 0028 one-fundamental-per-
// assertion): 3 is a *blocked* turn holding pac in place (no auto-detour), 8's first
// checkpoint is an isolated *open* turn changing pac's heading. Step 9 (Refs #102) is a
// targeted regression guard, not a mechanic rung: it re-pins Pinky's quantitative
// ambush-offset arithmetic, which used to ride on step 7 before #108 re-pointed 7 to
// Blinky's chase target. Step 10 (issue #164) is another targeted regression guard: every
// prior vertical-movement check pressed only "up" (dr=-1), so it rides step 8's exact
// up trip and then presses "down", proving dr=+1 (increasing world-y, downward on
// screen) works too — the direction #159/#161's orientation fix could regress without
// any other step noticing. -----

test "pacman scenario [spawn]: pac, four ghosts, and the curated pickups materialize" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/01_spawn.zon");
}

test "pacman scenario [move]: with no input pac steers along its default heading" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/02_move.zon");
}

test "pacman scenario [turn]: an on_key press for a direction blocked at pac's own column holds pac in place, never detouring around the wall" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/03_turn.zon");
}

test "pacman scenario [eat]: pac's path crosses a dot and eats it, raising its score" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/04_eat.zon");
}

test "pacman scenario [ghost collision]: a non-frightened catch resets pac, not a kill" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/05_ghost_collision.zon");
}

test "pacman scenario [frightened catch]: eating a power pellet frightens every ghost, and a catch sends one home" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/06_frightened_catch.zon");
}

test "pacman scenario [mode flip]: the chase/scatter timer changes a ghost's target on both axes" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/07_mode_flip.zon");
}

test "pacman scenario [straight]: an open turn changes pac's heading, then pac holds it through the row-7 crossing and stops dead at the interior wall, never detouring sideways (#108)" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/08_straight_through.zon");
}

test "pacman scenario [ambush]: in chase mode Pinky targets PINKY_AHEAD (4) cells ahead of pac's heading (offset arithmetic regression guard, Refs #102)" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/09_pinky_ambush.zon");
}

test "pacman scenario: two independent replays of the eat staircase agree bit-for-bit" {
    try requireLua();
    try expectDeterministic(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/04_eat.zon");
}

test "pacman scenario: two independent replays of the mode-flip staircase agree bit-for-bit" {
    try requireLua();
    try expectDeterministic(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/07_mode_flip.zon");
}

test "pacman scenario [down]: pressing down after reaching row 7 rides column 8 back down to pac's start row (dr=+1, issue #164 — no scenario had ever pressed 'down')" {
    try requireLua();
    try expectScenarioPasses(std.testing.allocator, std.testing.io, pacman_paths, "games/pacman/scenarios/10_down_through.zon");
}
