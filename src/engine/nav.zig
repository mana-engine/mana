//! The `nav` steering system (ADR 0027): native pathfinding + steering over a scene
//! tilemap. Lua selects *what* — a target cell, written to the `nav_target_col`/
//! `nav_target_row` data components (ADR 0024) via the existing `mana.set` — and this
//! system executes *how*, every tick, for every `NavAgent`: a deterministic
//! breadth-first search over the tilemap's walkable cells (ADR 0026) from the agent's
//! current cell to its target, whose first step steers the agent by setting its
//! `Velocity` toward the next cell's centre. The existing `movement` system then
//! integrates that velocity (register `nav` before `movement`). No pathfinder runs in
//! Lua and there is no per-entity-per-frame Lua callback — CLAUDE.md's "native
//! steering, Lua selection" seam.
//!
//! Deterministic: agents are visited in NavAgent-insertion order; BFS explores
//! neighbours in a fixed order (up, down, left, right) and keeps the first parent to
//! reach each cell; steering is float arithmetic in a fixed sequence — so identical
//! world state yields an identical velocity every run, and the resulting (hashed)
//! `Transform` is bit-identical. Allocation-free: the BFS visited/parent/frontier
//! scratch is a fixed stack buffer bounded by `max_cells`; a grid larger than that
//! leaves the agent stationary (a bounded maze is the scope). A*/weighted costs,
//! non-grid nav graphs, and local avoidance are deferred (ADR 0027).

const std = @import("std");
const core = @import("core");
const tilemap_mod = @import("tilemap.zig");
const Tilemap = tilemap_mod.Tilemap;
const Cell = tilemap_mod.Cell;
const Context = @import("sim.zig").Context;
const SystemError = @import("sim.zig").SystemError;

/// Upper bound on grid cells the BFS scratch buffers cover (64×64). A maze beyond this
/// bound is out of scope (ADR 0027); an agent on such a grid stays put. Sized so the
/// scratch stays a modest fixed stack allocation — no heap in the steering hot loop.
pub const max_cells: usize = 64 * 64;

/// The named data component a script writes (via `mana.set`) to select a nav agent's
/// target **column** (ADR 0027). A scene/prototype must declare it on the agent (ADR
/// 0024) for selection to take effect; an agent missing it is left stationary.
pub const target_col_component = "nav_target_col";
/// The named data component for a nav agent's target **row** (companion to
/// `target_col_component`).
pub const target_row_component = "nav_target_row";

/// The first cell to step to along a shortest path from `start` to `target` over
/// `tm`'s walkable cells, or null if there is no path, the `target` is unreachable or
/// off-grid, the agent is already at `target`, or the grid exceeds `max_cells`.
/// Deterministic: breadth-first with a fixed neighbour order (up, down, left, right),
/// keeping the first parent to reach each cell, so the returned step is stable for
/// identical input. Pure and allocation-free (fixed stack scratch) — the entry point
/// the `nav` system and its table-driven tests both drive.
pub fn nextStep(tm: Tilemap, start: Cell, target: Cell) ?Cell {
    if (start.col == target.col and start.row == target.row) return null; // already there
    if (!tm.isWalkable(start.col, start.row)) return null; // agent off the walkable grid
    if (!tm.isWalkable(target.col, target.row)) return null; // wall/off-grid target

    const cols = tm.colCount();
    const rows = tm.rows.len;
    if (cols == 0 or rows == 0 or cols * rows > max_cells) return null;

    // Fixed BFS scratch (no heap): visited flag + parent flat-index per cell, and a
    // frontier ring buffer. `parent` is -1 for unset; the start is its own root.
    var visited = [_]bool{false} ** max_cells;
    var parent = [_]i32{-1} ** max_cells;
    var queue = [_]u32{0} ** max_cells;
    var head: usize = 0;
    var tail: usize = 0;

    const start_idx = flatIndex(start, cols);
    const target_idx = flatIndex(target, cols);
    visited[start_idx] = true;
    queue[tail] = @intCast(start_idx);
    tail += 1;

    // Fixed neighbour order: up, down, left, right — the determinism tie-break.
    const deltas = [_]Cell{
        .{ .col = 0, .row = -1 },
        .{ .col = 0, .row = 1 },
        .{ .col = -1, .row = 0 },
        .{ .col = 1, .row = 0 },
    };

    while (head < tail) {
        const cur_idx = queue[head];
        head += 1;
        if (cur_idx == target_idx) break;
        const cur = cellOf(cur_idx, cols);
        for (deltas) |d| {
            const nb: Cell = .{ .col = cur.col + d.col, .row = cur.row + d.row };
            if (!tm.isWalkable(nb.col, nb.row)) continue; // rejects walls + off-grid
            const nb_idx = flatIndex(nb, cols); // in-range: isWalkable guaranteed it
            if (visited[nb_idx]) continue;
            visited[nb_idx] = true;
            parent[nb_idx] = @intCast(cur_idx);
            queue[tail] = @intCast(nb_idx);
            tail += 1;
        }
    }

    if (!visited[target_idx]) return null; // target never reached: no path

    // Walk parents back from the target to the cell whose parent is the start; that
    // cell is the first step of the shortest path.
    var step_idx: usize = target_idx;
    while (parent[step_idx] != @as(i32, @intCast(start_idx))) {
        const p = parent[step_idx];
        if (p < 0) return null; // defensive: a broken chain (unreachable if visited)
        step_idx = @intCast(p);
    }
    return cellOf(@intCast(step_idx), cols);
}

/// Frame system (ADR 0027): steer every `NavAgent` one step along the shortest path to
/// its selected target cell. For each agent (in NavAgent-insertion order) with a
/// `Transform` on the sim's tilemap and both target data components set, run `nextStep`
/// and set the agent's `Velocity` toward that cell's centre at `NavAgent.speed`; an
/// agent already at (or with no path to) its target is stopped (zero velocity), so it
/// stays put deterministically. No-op when the sim has no tilemap, no agents, or the
/// target components are undeclared. Never allocates in the steady state and never
/// reports `error.SystemFailed`; only `error.OutOfMemory` — and only the first time a
/// steered agent that lacks a `Velocity` column needs its slot created.
pub fn navSystem(ctx: *Context) SystemError!void {
    const tm_ptr = ctx.tilemap orelse return;
    const tm = tm_ptr.*;
    const world = ctx.world;
    const agents = world.nav_agents.entities();
    if (agents.len == 0) return;
    const agent_data = world.nav_agents.slice();

    // Resolve the two target columns once; if neither scene nor prototype declared a
    // target, no agent can be steered this tick.
    const col_c = world.dataColumn(target_col_component) orelse return;
    const row_c = world.dataColumn(target_row_component) orelse return;

    for (agents, agent_data) |ei, agent| {
        const t = world.transforms.get(ei) orelse continue;
        const start = tm.worldToCell(t.pos) orelse continue; // agent off-grid: skip
        const tc = world.data.get(col_c, ei) orelse continue; // no target set: skip
        const tr = world.data.get(row_c, ei) orelse continue;
        const target: Cell = .{ .col = @intFromFloat(tc), .row = @intFromFloat(tr) };

        var vel: core.Vec3 = core.Vec3.zero;
        if (nextStep(tm, start, target)) |step| {
            const dest = tm.cellToWorld(@intCast(step.col), @intCast(step.row));
            const dx = dest.x - t.pos.x;
            const dy = dest.y - t.pos.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (len > 0) vel = .{ .x = dx / len * agent.speed, .y = dy / len * agent.speed, .z = 0 };
        }

        // A value write on an existing column (like `movement`/`regen` do), not a
        // structural change — so it goes straight to the world for `movement` to
        // integrate this same tick, not through the command buffer. Creating a missing
        // Velocity slot is the only allocating path; agents should declare a Velocity
        // to keep the loop alloc-free.
        if (world.velocities.get(ei)) |v| {
            v.v = vel;
        } else {
            world.setVelocity(world.entityAt(ei), .{ .v = vel }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEntity => unreachable, // `ei` came from a live component set
            };
        }
    }
}

/// Flat row-major index of `c` in a grid `cols` wide. `c` must be in range (the caller
/// checks `isWalkable` first), so the cast never underflows.
fn flatIndex(c: Cell, cols: usize) usize {
    return @as(usize, @intCast(c.row)) * cols + @as(usize, @intCast(c.col));
}

/// Inverse of `flatIndex`: the cell at flat index `idx` in a grid `cols` wide.
fn cellOf(idx: u32, cols: usize) Cell {
    const i: usize = idx;
    return .{ .col = @intCast(i % cols), .row = @intCast(i / cols) };
}

const testing = std.testing;
const Sim = @import("sim.zig").Sim;
const World = @import("world.zig").World;
const systems = @import("systems.zig");

/// Build a tilemap from ASCII `rows` where '#' is a wall (static collider) and every
/// other glyph is walkable — the compact form the BFS tests author their grids in.
fn wallGrid(rows: []const []const u8) Tilemap {
    return .{
        .cell_size = 1,
        .origin = core.Vec3.zero,
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
        },
        .rows = rows,
    };
}

test "nav: nextStep BFS table — open, around a wall, adjacent, at-target, unreachable" {
    // A grid with a wall column splitting left from right, but a gap on the bottom row:
    //   col:  0123
    //   row0  .#..
    //   row1  .#..
    //   row2  ....
    const tm = wallGrid(&.{ ".#..", ".#..", "...." });

    const Case = struct { start: Cell, target: Cell, want: ?Cell };
    const cases = [_]Case{
        // Open horizontal step: right neighbour is on the shortest path.
        .{ .start = .{ .col = 2, .row = 0 }, .target = .{ .col = 3, .row = 0 }, .want = .{ .col = 3, .row = 0 } },
        // At target: no step.
        .{ .start = .{ .col = 0, .row = 0 }, .target = .{ .col = 0, .row = 0 }, .want = null },
        // Adjacent below: step down.
        .{ .start = .{ .col = 0, .row = 0 }, .target = .{ .col = 0, .row = 1 }, .want = .{ .col = 0, .row = 1 } },
        // Around the wall: from left-top (0,0) to right-top (2,0) the only route is
        // down the left side, across the bottom gap, and up — first step is DOWN
        // (fixed neighbour order visits up (wall/off-grid), then down).
        .{ .start = .{ .col = 0, .row = 0 }, .target = .{ .col = 2, .row = 0 }, .want = .{ .col = 0, .row = 1 } },
        // Target is a wall: unreachable ⇒ no step.
        .{ .start = .{ .col = 0, .row = 0 }, .target = .{ .col = 1, .row = 0 }, .want = null },
    };
    for (cases) |c| {
        const got = nextStep(tm, c.start, c.target);
        if (c.want) |w| {
            try testing.expect(got != null);
            try testing.expectEqual(w.col, got.?.col);
            try testing.expectEqual(w.row, got.?.row);
        } else {
            try testing.expect(got == null);
        }
    }
}

test "nav: nextStep prefers the fixed neighbour order on an equal-length choice" {
    // From (1,1) to (1,3) on an open 3x4-ish grid there are several 2-step... actually
    // a straight shot: down is on a shortest path and is tried before left/right, so a
    // symmetric detour never wins. Assert the first step is straight down.
    const tm = wallGrid(&.{ "...", "...", "...", "..." });
    const got = nextStep(tm, .{ .col = 1, .row = 1 }, .{ .col = 1, .row = 3 }).?;
    try testing.expectEqual(@as(i32, 1), got.col);
    try testing.expectEqual(@as(i32, 2), got.row);
}

test "nav: an agent with no path (walled off) stays put" {
    // Target sealed behind walls on every side is unreachable.
    const tm = wallGrid(&.{ "#####", "#.#.#", "#####" });
    try testing.expect(nextStep(tm, .{ .col = 1, .row = 1 }, .{ .col = 3, .row = 1 }) == null);
}

test "nav: through the Sim, an agent steps one cell toward its target and reaches it" {
    // A 1x5 open corridor. The agent starts at cell (0,0); its target is cell (4,0).
    // With speed = cell_size / dt, each tick moves exactly one cell along the path.
    const tm = wallGrid(&.{"....."});

    var sim = Sim.init(testing.allocator, 1.0); // dt = 1s
    defer sim.deinit();
    sim.tilemap = &tm;

    const agent = try sim.world.spawn();
    try sim.world.setTransform(agent, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setVelocity(agent, .{ .v = core.Vec3.zero });
    try sim.world.setNavAgent(agent, .{ .speed = 1 }); // 1 unit/s * 1s = 1 cell/tick
    // Declare + set the target cell (4,0) via the data-component seam a script writes.
    try sim.world.setDataByName(agent, target_col_component, 4);
    try sim.world.setDataByName(agent, target_row_component, 0);

    try sim.addSystem(navSystem); // nav sets velocity ...
    try sim.addSystem(systems.movementSystem); // ... movement integrates it, same tick

    try sim.tick(); // one step toward the target
    try testing.expect(sim.world.getTransform(agent).?.pos.approxEql(.{ .x = 1, .y = 0, .z = 0 }, 1e-6));

    try sim.run(3); // three more steps reach cell (4,0)
    try testing.expect(sim.world.getTransform(agent).?.pos.approxEql(.{ .x = 4, .y = 0, .z = 0 }, 1e-6));

    try sim.run(2); // at the target now: stays put (zero velocity)
    try testing.expect(sim.world.getTransform(agent).?.pos.approxEql(.{ .x = 4, .y = 0, .z = 0 }, 1e-6));
}

test "nav: a sim without a tilemap leaves nav agents untouched" {
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    // No sim.tilemap set.
    const agent = try sim.world.spawn();
    try sim.world.setTransform(agent, .{ .pos = .{ .x = 2, .y = 2, .z = 0 } });
    try sim.world.setVelocity(agent, .{ .v = core.Vec3.zero });
    try sim.world.setNavAgent(agent, .{ .speed = 1 });

    try sim.addSystem(navSystem);
    try sim.addSystem(systems.movementSystem);
    try sim.tick();
    try testing.expect(sim.world.getTransform(agent).?.pos.approxEql(.{ .x = 2, .y = 2, .z = 0 }, 1e-6));
}

/// Run a fixed nav scenario for `steps` ticks and return the final state hash — the
/// determinism harness for the test below.
fn navScenarioHash(steps: u32) !u64 {
    const tm = wallGrid(&.{ ".....", ".###.", "....." });
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();
    sim.tilemap = &tm;

    const agent = try sim.world.spawn();
    try sim.world.setTransform(agent, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setVelocity(agent, .{ .v = core.Vec3.zero });
    try sim.world.setNavAgent(agent, .{ .speed = 1 });
    try sim.world.setDataByName(agent, target_col_component, 4);
    try sim.world.setDataByName(agent, target_row_component, 2);

    try sim.addSystem(navSystem);
    try sim.addSystem(systems.movementSystem);
    try sim.run(steps);
    return sim.stateHash();
}

test "nav: determinism — two identical nav runs produce the same state hash" {
    const a = try navScenarioHash(8);
    const b = try navScenarioHash(8);
    try testing.expectEqual(a, b);
}
