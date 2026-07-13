//! Behavioral acceptance PoC for ADR 0028 (layer-1 + PoC): drive the *real*
//! `games/snake` package headlessly and assert **semantic** outcomes the determinism
//! hash cannot express — the snake advances, turns on input, reaches and eats food,
//! grows, and resets on death — while the universal invariants (`engine.invariants`)
//! hold every tick. Everything runs off primitives that already exist: input-trace
//! replay (`Sim.setInput`, one snapshot per tick), state queries (component
//! positions, entity count), and the invariant checker. No new file format, no new
//! runner mode (those are ADR 0028 layer-2 follow-ups).
//!
//! **Structured as a localizing staircase** (ADR 0028 design tenet): each mechanic is
//! its own named test, ordered from spawn → advance → turn → eat → grow → death. A red
//! test therefore pinpoints the broken mechanic ("turning broke") rather than reporting
//! that "the snake broke". This is content-side genre knowledge (snake cells, headings,
//! food) living in the *test*, never in `src/` (CLAUDE.md invariant #6): the engine ships
//! only the generic referee.
//!
//! **Determinism.** The snake's food PRNG is content-side and seeded from a constant, so
//! the first food lands at grid cell (-2,-1) every run; the move timer (`mana.every`,
//! 0.15 s at dt = 1/60) fires a grid step at ticks 8, 17, 26, 35, … The input traces
//! below are authored against that fixed schedule, so the whole PoC is bit-reproducible.
//!
//! Gated on `-Denable-lua`: without the scripting backend `games/snake` cannot run, so
//! every test skips (its logic lives entirely in `rules.lua`). Files are read from the
//! package relative to the build's cwd, which integration tests may reference (the game
//! corpus) — `src/**` may not.

const std = @import("std");
const core = @import("core");
const engine = @import("engine");

const Io = std.Io;
const Key = engine.platform.Key;

/// A loaded, ready-to-drive `games/snake` sim plus the package sources it borrows.
/// Owns everything; `deinit` tears the sim down before freeing the prototype/scene the
/// registry borrowed. Heap-allocated so the borrowed prototype slice stays pinned.
const Snake = struct {
    gpa: std.mem.Allocator,
    proto_src: [:0]u8,
    proto_file: engine.prototype.File,
    scene_src: [:0]u8,
    scene: engine.Scene,
    rules: [:0]u8,
    sim: engine.Sim,

    /// Load `games/snake` exactly as the runner's one-shot path does (prototypes →
    /// scene → Lua rules → enter scene → movement/regen systems), leaving the sim at
    /// tick 0 ready to be driven. Caller owns the result; call `deinit`.
    fn load(gpa: std.mem.Allocator, io: Io) !*Snake {
        const self = try gpa.create(Snake);
        errdefer gpa.destroy(self);
        self.gpa = gpa;

        self.proto_src = try readPkg(gpa, io, "games/snake/prototypes.zon");
        errdefer gpa.free(self.proto_src);
        self.proto_file = try engine.prototype.parse(gpa, self.proto_src);
        errdefer engine.prototype.free(gpa, self.proto_file);

        self.scene_src = try readPkg(gpa, io, "games/snake/scenes/board.zon");
        errdefer gpa.free(self.scene_src);
        self.scene = try engine.scene.parse(gpa, self.scene_src);
        errdefer engine.scene.free(gpa, self.scene);

        self.rules = try readPkg(gpa, io, "games/snake/rules.lua");
        errdefer gpa.free(self.rules);

        self.sim = engine.Sim.init(gpa, core.time.default_dt);
        errdefer self.sim.deinit();
        self.sim.prototypes = .{ .prototypes = self.proto_file.prototypes };
        try engine.scene.load(self.scene, &self.sim.world);
        try self.sim.loadScript(self.rules);
        self.sim.enterScene(self.scene.name);
        try self.sim.addSystem(engine.systems.movementSystem);
        try self.sim.addSystem(engine.systems.regenSystem);
        return self;
    }

    fn deinit(self: *Snake) void {
        const gpa = self.gpa;
        self.sim.deinit();
        engine.prototype.free(gpa, self.proto_file);
        engine.scene.free(gpa, self.scene);
        gpa.free(self.proto_src);
        gpa.free(self.scene_src);
        gpa.free(self.rules);
        gpa.destroy(self);
    }

    /// Advance `n` ticks with `held` keys pressed each tick (an `on_key` edge fires only
    /// when the held set *changes* between ticks). After every tick the universal
    /// invariants must hold — a violation fails the run with the tick + offending entity.
    fn run(self: *Snake, n: u32, held: []const Key) !void {
        var snap: engine.platform.InputSnapshot = .{};
        for (held) |k| snap.keys.insert(k);
        for (0..n) |_| {
            self.sim.setInput(snap);
            try self.sim.tick();
            if (engine.invariants.check(&self.sim.world, null)) |v| {
                std.debug.print("invariant violated at tick {d}: {f}\n", .{ self.sim.tick_count, v });
                return error.InvariantViolated;
            }
        }
    }

    /// True if any entity's transform is at grid cell (`x`, `y`) (cell size 1, board
    /// centred on the origin). The snake, food, and walls are all transform-only, so a
    /// cell is identified by position — the only genre knowledge the engine never has.
    fn occupied(self: *Snake, x: f32, y: f32) bool {
        for (self.sim.world.transforms.values.items) |t| {
            if (@abs(t.pos.x - x) < 0.01 and @abs(t.pos.y - y) < 0.01) return true;
        }
        return false;
    }

    /// Number of entities inside the play field [-8,7]² — the snake segments plus the
    /// one food. The wall ring sits at ±(HALF+1) = {-9, 8}, outside this window, so it
    /// is excluded. `segments = interior − 1` (the single food).
    fn interiorCount(self: *Snake) usize {
        var n: usize = 0;
        for (self.sim.world.transforms.values.items) |t| {
            if (t.pos.x >= -8.5 and t.pos.x <= 7.5 and t.pos.y >= -8.5 and t.pos.y <= 7.5) n += 1;
        }
        return n;
    }
};

fn readPkg(gpa: std.mem.Allocator, io: Io, rel: []const u8) ![:0]u8 {
    return Io.Dir.cwd().readFileAllocOptions(io, rel, gpa, .unlimited, .of(u8), 0);
}

/// Skip the whole staircase unless the Lua backend is compiled in (games/snake is pure
/// Lua). `script_api_version` is 0 without `-Denable-lua`.
fn requireLua() !void {
    if (engine.script_api_version == 0) return error.SkipZigTest;
}

// --- The staircase: each step isolates one mechanic (ADR 0028) --------------------

test "snake acceptance [spawn]: bootstrap places the head at origin, one food, a wall ring" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    try s.run(6, &.{}); // settle the bootstrap spawns; first grid step is not until tick 8
    try std.testing.expect(s.occupied(0, 0)); // the head starts at the world origin
    try std.testing.expect(s.occupied(-2, -1)); // the deterministic first food cell
    try std.testing.expectEqual(@as(usize, 2), s.interiorCount()); // exactly head + food
    try std.testing.expect(s.sim.world.count() > 50); // the wall ring materialized
}

test "snake acceptance [advance]: with no input the snake steps one cell along its facing" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    // Grid step 1 fires at tick 8, but the head's `mana.set_position` is deferred and
    // lands at the next flush (tick 9), so run through tick 9 to observe it.
    try s.run(10, &.{}); // through grid step 1 + its flush: head (0,0) -> (1,0), facing right
    try std.testing.expect(s.occupied(1, 0));
    try std.testing.expect(!s.occupied(0, 0)); // the head vacated the origin

    try s.run(9, &.{}); // through grid step 2 (tick 17) + its flush (tick 18): head -> (2,0)
    try std.testing.expect(s.occupied(2, 0));
    try std.testing.expect(!s.occupied(1, 0)); // one cell per step, not a smear
}

test "snake acceptance [turn]: an on_key press turns the snake off its default heading" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    // Hold DOWN from tick 0; the press edge sets the pending heading before grid step 1
    // (tick 8), whose deferred `set_position` lands at the next flush (tick 9).
    try s.run(10, &[_]Key{.down}); // through grid step 1 + its flush
    try std.testing.expect(s.occupied(0, -1)); // turned: head went DOWN, not right
    try std.testing.expect(!s.occupied(1, 0)); // it did NOT keep its default rightward heading
}

test "snake acceptance [eat]: steering the head onto the food cell reaches it" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    // Steer (0,0) -> (0,-1) -> (-1,-1) -> (-2,-1) = the food. A 180° reversal of the
    // committed heading is rejected, so turn DOWN first (tick 0), then LEFT once that
    // has committed (tick 12, between grid steps 1 and 2 at ticks 8 and 17).
    try s.run(12, &[_]Key{.down}); // ticks 0..11: grid step 1 -> head (0,-1)
    try s.run(18, &[_]Key{.left}); // ticks 12..29: steps 2,3 -> head (-1,-1) -> (-2,-1)
    try std.testing.expect(s.occupied(-2, -1)); // the head reached the food cell
}

test "snake acceptance [grow]: length increases by one after eating (the hash cannot see this)" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    try s.run(6, &[_]Key{.down}); // ticks 0..5: bootstrap settled, no eat yet
    const before = s.sim.world.count();
    const before_interior = s.interiorCount(); // 2: one segment (head) + one food

    try s.run(6, &[_]Key{.down}); // ticks 6..11: grid step 1 -> (0,-1)
    try s.run(18, &[_]Key{.left}); // ticks 12..29: steps 2,3 -> eat at (-2,-1)

    // The semantic outcome no state hash can express: the snake grew by exactly one
    // segment. Entity count +1 (a new segment; the food is repositioned, not respawned),
    // and the play field now holds head + new segment + food = 3.
    try std.testing.expectEqual(before + 1, s.sim.world.count());
    try std.testing.expectEqual(before_interior + 1, s.interiorCount());
}

test "snake acceptance [death]: running into the wall resets the run to the origin" {
    try requireLua();
    const gpa = std.testing.allocator;
    var s = try Snake.load(gpa, std.testing.io);
    defer s.deinit();

    try s.run(6, &.{}); // ticks 0..5: settled bootstrap
    const before = s.sim.world.count();

    // No input: the snake runs right, reaching (7,0) at grid step 7 (tick 63); grid step
    // 8 (tick 72) walks it into the wall at x=8, which resets the run — a fresh head at
    // the origin, length back to 1. Run past the reset but before the next step (tick 81).
    try s.run(72, &.{}); // ticks 6..77
    try std.testing.expect(s.occupied(0, 0)); // the head respawned at the origin
    try std.testing.expectEqual(before, s.sim.world.count()); // died at length 1, reset to 1
    try std.testing.expectEqual(@as(usize, 2), s.interiorCount()); // head + food, no leftover body
}

test "snake acceptance [determinism]: two identical runs agree bit-for-bit (state hash + count)" {
    try requireLua();
    const gpa = std.testing.allocator;

    var a = try Snake.load(gpa, std.testing.io);
    defer a.deinit();
    var b = try Snake.load(gpa, std.testing.io);
    defer b.deinit();

    // The same authored eat trace on two fresh sims must reach a bit-identical state.
    inline for (.{ a, b }) |s| {
        try s.run(12, &[_]Key{.down});
        try s.run(18, &[_]Key{.left});
    }
    try std.testing.expectEqual(a.sim.world.count(), b.sim.world.count());
    try std.testing.expectEqual(a.sim.stateHash(), b.sim.stateHash());
}
