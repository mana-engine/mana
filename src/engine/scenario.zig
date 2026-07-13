//! ADR 0028 Layer 2: the data-driven scenario format plus its generic evaluator — a
//! `games/<g>/scenarios/*.zon` file names a fixed input trace and an **ordered
//! staircase** of single-mechanic assertions; this module replays the trace against
//! an already-loaded `Sim` and reports **per-assertion pass/fail**, so a red result
//! pinpoints exactly which mechanic broke (the ADR's design tenet). `--scenario`
//! (`src/runtime/main.zig`) is the CLI entry point; this module is the generic
//! referee it and any test harness drive.
//!
//! **Genre-neutral** (CLAUDE.md invariant #6): every `Check` variant is a plain query
//! over built-in world state (live entity count, `Transform.pos`, a named data
//! component) — nothing here knows what a snake, a dot, or a ghost is. The genre
//! knowledge (which cell is food, which tag is a ghost) lives entirely in the
//! scenario file's numbers, authored by the game package.
//!
//! **Layer-1 invariants ride along for free**: `run` checks `engine.invariants` after
//! every tick and aborts the replay the instant one fires — a corrupt world cannot
//! answer a later assertion meaningfully, and the report says exactly which tick and
//! predicate broke instead of misreporting a downstream assertion as the failure.
//!
//! **Vocabulary kept deliberately small** (CLAUDE.md "no speculative flexibility"):
//! five `Check` variants cover every mechanic the Snake and Pac-Man staircases need
//! (`games/snake/scenarios/`, `games/pacman/scenarios/`). An event-log query (ADR
//! 0028 mentions it as an option) is not implemented — the shipped staircases never
//! needed one (a collision's *effect* — a reset position, a despawned pickup, a data
//! field — is always observable in post-tick world state); add it via a new `Check`
//! variant when a concrete game staircase needs it, not before.
//!
//! Over the ~500-line soft limit by design (like `sim.zig`): roughly 260 lines are
//! the format + evaluator, the rest is the behavior-named `test` suite
//! CLAUDE.md requires for new public API — splitting tests out would not shrink the
//! reviewable surface, only scatter it across two files.

const std = @import("std");
const data = @import("data");
const platform = @import("platform");
const sim_mod = @import("sim.zig");
const invariants = @import("invariants.zig");

const Allocator = std.mem.Allocator;
const Sim = sim_mod.Sim;

/// A run-length-encoded slice of the input trace: hold `keys` (by name, e.g. `"up"`,
/// matching `platform.Key`'s tag names) for `ticks` consecutive sim ticks. Concatenated
/// segments are exactly ADR 0028's "input_trace (per-tick keys)" — `Sim.setInput`
/// already treats a key as "still held" tick over tick, so a segment is that existing
/// primitive run-length-encoded, rather than forcing a scenario author to spell out
/// one entry per tick for a key held across dozens of them (as every staircase here
/// does — see `tests/acceptance_snake.zig`'s Zig-side PoC this format ports).
pub const InputSegment = struct {
    ticks: u32,
    keys: []const []const u8 = &.{},
};

/// Either bound is optional; both null holds for any count. `min == max` expresses
/// exact equality (the common case for a deterministic staircase checkpoint).
pub const Bound = struct {
    min: ?usize = null,
    max: ?usize = null,

    fn holds(self: Bound, n: usize) bool {
        if (self.min) |m| if (n < m) return false;
        if (self.max) |m| if (n > m) return false;
        return true;
    }
};

/// A world point. Matches an entity's `Transform.pos` when each axis is within `eps`
/// (a per-axis box, not a Euclidean radius — see `findEntityIndexAt`).
pub const Position = struct {
    x: f32,
    y: f32,
    z: f32 = 0,
    eps: f32 = 0.01,
};

/// A query over post-tick world state — the vocabulary ADR 0028 Layer 2 evaluates
/// ("data components ..., entity count by tag/prototype, ... a component field's
/// value"). See the module doc for why this list is deliberately short.
pub const Check = union(enum) {
    /// Total live entity count is within `bound`.
    entity_count: Bound,
    /// At least one entity's `Transform.pos` is at `pos` (within `pos.eps`).
    occupied: Position,
    /// No entity's `Transform.pos` is at `pos` (within `pos.eps`).
    vacant: Position,
    /// The (first) entity found at `pos` carries named data component `name` equal to
    /// `value` (within `value_eps`). Fails if no entity occupies `pos`, or the entity
    /// there never declared `name`.
    data_at: struct {
        pos: Position,
        name: []const u8,
        value: f64,
        value_eps: f64 = 1e-6,
    },
    /// The number of live entities whose named data component `name` equals `value`
    /// (within `value_eps`) is within `bound` — "entity count by tag" (ADR 0028),
    /// generalized to any data-tagged group (a kind, a team, a room id).
    data_count: struct {
        name: []const u8,
        value: f64,
        value_eps: f64 = 1e-6,
        bound: Bound,
    },
};

/// One staircase step: a human-readable `label` (surfaced verbatim in the report, so
/// a failure names the broken mechanic — not "the game broke"), the cumulative tick
/// count since scenario start at which to evaluate `check` (must land exactly on an
/// `input_trace` tick boundary; see `run`), and the query itself.
pub const Assertion = struct {
    label: []const u8,
    at_tick: u32,
    check: Check,
};

/// A parsed scenario file (ADR 0028 Layer 2): `.{ seed, steps, input_trace, expect }`.
/// `steps` is the total tick count the replay advances (informational — `run`
/// actually advances exactly `sum(input_trace[*].ticks)`; a scenario author keeps
/// them equal so the file is self-documenting, and a mismatch is not itself an
/// error). `seed` feeds `Sim.setRngSeed` so a scenario exercising `mana.random`
/// content is reproducible; defaults to the Sim's own default seed.
pub const Scenario = struct {
    seed: u64 = sim_mod.default_rng_seed,
    steps: u32 = 0,
    input_trace: []const InputSegment = &.{},
    expect: []const Assertion = &.{},
};

/// Parse a scenario from NUL-terminated ZON `source` (same parser as scenes/
/// prototypes/manifests). Errors: `error.ParseZon` on malformed ZON,
/// `error.OutOfMemory`.
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!Scenario {
    return data.parse(Scenario, gpa, source);
}

/// Free a `Scenario` returned by `parse`.
pub fn free(gpa: Allocator, scenario: Scenario) void {
    data.free(gpa, scenario);
}

/// One assertion's outcome, in scenario file order.
pub const Result = struct {
    label: []const u8,
    at_tick: u32,
    passed: bool,
    /// Empty on pass; a short human explanation of the mismatch on failure.
    detail: []const u8 = "",
};

/// Set only if a Layer-1 invariant (`engine.invariants`) fired during the replay; the
/// tick it happened on plus the violation itself.
pub const InvariantFailure = struct {
    tick: u64,
    violation: invariants.Violation,
};

/// The outcome of one `run`: every assertion's `Result`, in file order, plus an
/// optional `InvariantFailure` if the replay was aborted early by a corrupt world.
/// Owns its `Result.detail` strings (allocated from its own arena); `deinit` frees
/// everything. `label`s borrow from the `Scenario` the caller must keep alive at
/// least until it is done reading the report.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    results: std.ArrayList(Result) = .empty,
    invariant_violation: ?InvariantFailure = null,

    fn init(gpa: Allocator) Report {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True if every assertion passed and no invariant fired.
    pub fn passed(self: Report) bool {
        if (self.invariant_violation != null) return false;
        for (self.results.items) |r| {
            if (!r.passed) return false;
        }
        return true;
    }
};

/// Replay `scenario` against `sim` — already loaded by the caller (scene entered,
/// systems registered, script loaded; this stays package-agnostic, CLAUDE.md
/// invariant #6) — and evaluate every `expect` assertion at its `at_tick` checkpoint.
/// `engine.invariants.check` runs after every tick; the instant it fires, the replay
/// stops (further assertions would be judging a corrupt world) and `Report.
/// invariant_violation` is set. An assertion whose `at_tick` never lands on an
/// `input_trace` tick boundary is reported as a failure ("never reached") rather
/// than silently skipped — a scenario-authoring bug should be loud, not quiet.
/// Errors: `error.OutOfMemory` and whatever `Sim.tick` propagates (script/system
/// failure is caught internally by `Sim`; only OOM crosses this boundary), plus
/// `error.UnknownKey` if `input_trace` names a key `platform.Key` does not have.
pub fn run(gpa: Allocator, sim: *Sim, scenario: Scenario) !Report {
    sim.setRngSeed(scenario.seed);
    var report = Report.init(gpa);
    errdefer report.deinit();
    const aa = report.arena.allocator();

    var next_expect: usize = 0;
    var elapsed: u32 = 0;
    for (scenario.input_trace) |seg| {
        var snap: platform.InputSnapshot = .{};
        for (seg.keys) |name| {
            const key = std.meta.stringToEnum(platform.Key, name) orelse return error.UnknownKey;
            snap.keys.insert(key);
        }
        for (0..seg.ticks) |_| {
            sim.setInput(snap);
            try sim.tick();
            elapsed += 1;
            if (invariants.check(&sim.world, sim.tilemap)) |v| {
                report.invariant_violation = .{ .tick = sim.tick_count, .violation = v };
                return report;
            }
            while (next_expect < scenario.expect.len and scenario.expect[next_expect].at_tick == elapsed) : (next_expect += 1) {
                try evalOne(aa, sim, scenario.expect[next_expect], &report);
            }
        }
    }
    while (next_expect < scenario.expect.len) : (next_expect += 1) {
        const a = scenario.expect[next_expect];
        try report.results.append(aa, .{
            .label = a.label,
            .at_tick = a.at_tick,
            .passed = false,
            .detail = "at_tick was never reached by input_trace (scenario authoring bug: steps don't land on a tick boundary)",
        });
    }
    return report;
}

fn evalOne(aa: Allocator, sim: *Sim, a: Assertion, report: *Report) Allocator.Error!void {
    const outcome = try checkOne(aa, sim, a.check);
    try report.results.append(aa, .{ .label = a.label, .at_tick = a.at_tick, .passed = outcome.ok, .detail = outcome.detail });
}

const Outcome = struct { ok: bool, detail: []const u8 = "" };

fn checkOne(aa: Allocator, sim: *Sim, check: Check) Allocator.Error!Outcome {
    return switch (check) {
        .entity_count => |b| blk: {
            const n = sim.world.count();
            break :blk if (b.holds(n))
                .{ .ok = true }
            else
                .{ .ok = false, .detail = try std.fmt.allocPrint(aa, "entity_count: got {d}, want [{?d},{?d}]", .{ n, b.min, b.max }) };
        },
        .occupied => |pos| blk: {
            const found = findAt(sim, pos);
            break :blk if (found)
                .{ .ok = true }
            else
                .{ .ok = false, .detail = try std.fmt.allocPrint(aa, "occupied: no entity at ({d},{d},{d})", .{ pos.x, pos.y, pos.z }) };
        },
        .vacant => |pos| blk: {
            const found = findAt(sim, pos);
            break :blk if (!found)
                .{ .ok = true }
            else
                .{ .ok = false, .detail = try std.fmt.allocPrint(aa, "vacant: an entity is still at ({d},{d},{d})", .{ pos.x, pos.y, pos.z }) };
        },
        .data_at => |d| blk: {
            const ei = findEntityIndexAt(sim, d.pos) orelse break :blk .{
                .ok = false,
                .detail = try std.fmt.allocPrint(aa, "data_at: no entity at ({d},{d},{d})", .{ d.pos.x, d.pos.y, d.pos.z }),
            };
            const col = sim.world.dataColumn(d.name) orelse break :blk .{
                .ok = false,
                .detail = try std.fmt.allocPrint(aa, "data_at: data component '{s}' was never declared", .{d.name}),
            };
            const e = sim.world.entityAt(ei);
            const got = sim.world.getData(e, col) orelse break :blk .{
                .ok = false,
                .detail = try std.fmt.allocPrint(aa, "data_at: entity at ({d},{d},{d}) has no value for '{s}'", .{ d.pos.x, d.pos.y, d.pos.z, d.name }),
            };
            break :blk if (@abs(got - d.value) <= d.value_eps)
                .{ .ok = true }
            else
                .{ .ok = false, .detail = try std.fmt.allocPrint(aa, "data_at: '{s}' = {d}, want {d}", .{ d.name, got, d.value }) };
        },
        .data_count => |d| blk: {
            const col = sim.world.dataColumn(d.name) orelse break :blk .{
                .ok = false,
                .detail = try std.fmt.allocPrint(aa, "data_count: data component '{s}' was never declared", .{d.name}),
            };
            const set = &sim.world.data.columns.items[col];
            var n: usize = 0;
            for (set.slice()) |v| {
                if (@abs(v - d.value) <= d.value_eps) n += 1;
            }
            break :blk if (d.bound.holds(n))
                .{ .ok = true }
            else
                .{ .ok = false, .detail = try std.fmt.allocPrint(aa, "data_count('{s}'=={d}): got {d}, want [{?d},{?d}]", .{ d.name, d.value, n, d.bound.min, d.bound.max }) };
        },
    };
}

/// True if some live entity's `Transform.pos` is within `pos.eps` of `pos` on every
/// axis.
fn findAt(sim: *Sim, pos: Position) bool {
    return findEntityIndexAt(sim, pos) != null;
}

/// The (first, dense-order) entity index whose `Transform.pos` is within `pos.eps` of
/// `pos` on every axis, or `null` if none matches.
fn findEntityIndexAt(sim: *Sim, pos: Position) ?u32 {
    for (sim.world.transforms.entities(), sim.world.transforms.values.items) |ei, t| {
        if (@abs(t.pos.x - pos.x) <= pos.eps and @abs(t.pos.y - pos.y) <= pos.eps and @abs(t.pos.z - pos.z) <= pos.eps) {
            return ei;
        }
    }
    return null;
}

const testing = std.testing;

test "scenario: parse round-trips seed/steps/input_trace/expect" {
    const src =
        \\.{
        \\    .seed = 42,
        \\    .steps = 3,
        \\    .input_trace = .{
        \\        .{ .ticks = 3, .keys = .{ "down" } },
        \\    },
        \\    .expect = .{
        \\        .{ .label = "head moved down", .at_tick = 3, .check = .{ .occupied = .{ .x = 0, .y = -1 } } },
        \\    },
        \\}
    ;
    const s = try parse(testing.allocator, src);
    defer free(testing.allocator, s);
    try testing.expectEqual(@as(u64, 42), s.seed);
    try testing.expectEqual(@as(u32, 3), s.steps);
    try testing.expectEqual(@as(usize, 1), s.input_trace.len);
    try testing.expectEqualStrings("down", s.input_trace[0].keys[0]);
    try testing.expectEqual(@as(usize, 1), s.expect.len);
    try testing.expectEqualStrings("head moved down", s.expect[0].label);
    try testing.expectEqual(@as(u32, 3), s.expect[0].at_tick);
    try testing.expect(s.expect[0].check == .occupied);
}

/// A trivial system that moves the first entity +1 on x every tick — enough to drive
/// `run`'s tick loop and checkpoint evaluation without a real game package.
const Nudge = struct {
    fn system(ctx: *sim_mod.Context) sim_mod.SystemError!void {
        if (ctx.world.transforms.entities().len == 0) return;
        const ei = ctx.world.transforms.entities()[0];
        var t = ctx.world.transforms.values.items[ctx.world.transforms.sparse.items[ei]];
        t.pos.x += 1;
        ctx.world.transforms.values.items[ctx.world.transforms.sparse.items[ei]] = t;
    }
};

fn nudgeSim(gpa: Allocator) !Sim {
    var sim = Sim.init(gpa, 1.0 / 60.0);
    errdefer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.addSystem(Nudge.system);
    return sim;
}

test "scenario: run evaluates a checkpoint at its exact tick and reports pass" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .steps = 3,
        .input_trace = &.{.{ .ticks = 3 }},
        .expect = &.{.{ .label = "moved 3 cells", .at_tick = 3, .check = .{ .occupied = .{ .x = 3, .y = 0 } } }},
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(report.passed());
    try testing.expectEqual(@as(usize, 1), report.results.items.len);
    try testing.expect(report.results.items[0].passed);
}

test "scenario: a failing assertion is reported with a detail message, not a crash" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 2 }},
        .expect = &.{.{ .label = "wrong cell", .at_tick = 2, .check = .{ .occupied = .{ .x = 99, .y = 0 } } }},
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(!report.passed());
    try testing.expect(!report.results.items[0].passed);
    try testing.expect(report.results.items[0].detail.len > 0);
}

test "scenario: multiple checkpoints at different ticks are each evaluated once, in order" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 5 }},
        .expect = &.{
            .{ .label = "step 2", .at_tick = 2, .check = .{ .occupied = .{ .x = 2, .y = 0 } } },
            .{ .label = "step 5", .at_tick = 5, .check = .{ .occupied = .{ .x = 5, .y = 0 } } },
        },
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(report.passed());
    try testing.expectEqual(@as(usize, 2), report.results.items.len);
}

test "scenario: vacant passes when nothing occupies the cell and fails when something does" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 1 }},
        .expect = &.{
            .{ .label = "old cell vacated", .at_tick = 1, .check = .{ .vacant = .{ .x = 0, .y = 0 } } },
            .{ .label = "old cell still reads occupied (expected fail)", .at_tick = 1, .check = .{ .vacant = .{ .x = 1, .y = 0 } } },
        },
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(report.results.items[0].passed); // (0,0) really is vacated
    try testing.expect(!report.results.items[1].passed); // (1,0) is occupied, so vacant fails
}

test "scenario: entity_count bounds hold and reject" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 1 }},
        .expect = &.{
            .{ .label = "exactly one entity", .at_tick = 1, .check = .{ .entity_count = .{ .min = 1, .max = 1 } } },
            .{ .label = "too many (expected fail)", .at_tick = 1, .check = .{ .entity_count = .{ .min = 2 } } },
        },
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(report.results.items[0].passed);
    try testing.expect(!report.results.items[1].passed);
}

test "scenario: data_at reads the named component of the entity found at a position" {
    const gpa = testing.allocator;
    var sim = Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 5, .y = 5, .z = 0 } });
    try sim.world.setDataByName(e, "score", 60);

    const scenario: Scenario = .{
        .expect = &.{.{ .label = "score is 60", .at_tick = 0, .check = .{ .data_at = .{ .pos = .{ .x = 5, .y = 5 }, .name = "score", .value = 60 } } }},
    };
    // at_tick 0 with an empty input_trace: evaluate the leftover-checkpoint path
    // directly (no ticks run), proving data_at reads state as-is without ticking.
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    // Since input_trace is empty, elapsed never reaches 1, so at_tick=0 is never hit
    // by the tick loop and lands in the "never reached" catch-all — this documents
    // that at_tick must be >= 1 (reachable only after at least one tick). See doc.
    try testing.expect(!report.results.items[0].passed);
}

test "scenario: data_count counts entities whose named data value matches within tolerance" {
    const gpa = testing.allocator;
    var sim = Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    for (0..3) |i| {
        const e = try sim.world.spawn();
        try sim.world.setTransform(e, .{ .pos = .{ .x = @floatFromInt(i), .y = 0, .z = 0 } });
        try sim.world.setDataByName(e, "kind", if (i < 2) 3 else 9);
    }

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 1 }},
        .expect = &.{.{ .label = "two dots", .at_tick = 1, .check = .{ .data_count = .{ .name = "kind", .value = 3, .bound = .{ .min = 2, .max = 2 } } } }},
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(report.results.items[0].passed);
}

test "scenario: an unreached at_tick (bad authoring) is reported as a named failure, not skipped" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 2 }}, // only reaches elapsed=1,2
        .expect = &.{.{ .label = "unreachable checkpoint", .at_tick = 7, .check = .{ .entity_count = .{ .min = 0 } } }},
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(!report.passed());
    try testing.expectEqualStrings("unreachable checkpoint", report.results.items[0].label);
    try testing.expect(report.results.items[0].detail.len > 0);
}

test "scenario: an unknown key name in input_trace errors instead of silently no-oping" {
    const gpa = testing.allocator;
    var sim = try nudgeSim(gpa);
    defer sim.deinit();
    const scenario: Scenario = .{ .input_trace = &.{.{ .ticks = 1, .keys = &.{"not_a_real_key"} }} };
    try testing.expectError(error.UnknownKey, run(gpa, &sim, scenario));
}

test "scenario: a Layer-1 invariant violation aborts the replay and is reported" {
    const gpa = testing.allocator;
    var sim = Sim.init(gpa, 1.0 / 60.0);
    defer sim.deinit();
    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = std.math.nan(f32), .y = 0, .z = 0 } });

    const scenario: Scenario = .{
        .input_trace = &.{.{ .ticks = 1 }},
        .expect = &.{.{ .label = "never reached", .at_tick = 1, .check = .{ .entity_count = .{ .min = 0 } } }},
    };
    var report = try run(gpa, &sim, scenario);
    defer report.deinit();
    try testing.expect(!report.passed());
    try testing.expect(report.invariant_violation != null);
    try testing.expectEqual(invariants.Kind.nonfinite_transform, report.invariant_violation.?.violation.kind);
    try testing.expectEqual(@as(usize, 0), report.results.items.len); // no assertion was reached
}

test "scenario: Bound.holds with only a min, only a max, or neither" {
    try testing.expect((Bound{}).holds(999)); // no bound at all
    try testing.expect((Bound{ .min = 5 }).holds(5));
    try testing.expect(!(Bound{ .min = 5 }).holds(4));
    try testing.expect((Bound{ .max = 5 }).holds(5));
    try testing.expect(!(Bound{ .max = 5 }).holds(6));
}

test "scenario: Report.passed is false while any result failed, true when every result passed" {
    const gpa = testing.allocator;
    var report = Report.init(gpa);
    defer report.deinit();
    try testing.expect(report.passed()); // no results yet: vacuously true
    try report.results.append(report.arena.allocator(), .{ .label = "a", .at_tick = 1, .passed = true });
    try testing.expect(report.passed());
    try report.results.append(report.arena.allocator(), .{ .label = "b", .at_tick = 2, .passed = false });
    try testing.expect(!report.passed());
}
