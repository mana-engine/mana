//! Universal sim invariants (ADR 0028 layer 1): always-true predicates over world
//! state that hold for *any* correct simulation, whatever the genre. They are the
//! behavioral floor beneath the determinism hash (`World.stateHash`): the hash proves
//! output did not *change*, these prove output is not *corrupt or impossible*. A
//! deterministically-wrong sim (an entity teleported to NaN, health below zero, a
//! steered agent resting inside a wall) yields a perfectly stable hash but fails here.
//!
//! **Strictly genre-neutral** (CLAUDE.md invariant #6): nothing here knows what a
//! maze, a snake, a ghost, or a player is. Every predicate is phrased over built-in
//! components and the generic tilemap only.
//!
//! **Cost model.** `check` is a pure read-only pass with **no allocation** and is
//! **never called from `Sim.tick`** — the hot frame pays nothing in any build by
//! construction. It is opt-in: a test, a debug harness, or the future `--scenario`
//! runner (ADR 0028 layer 2) drives it, per tick or once post-run. This keeps CLAUDE.md
//! invariant #3 (no per-frame cost in the default build) without a comptime flag.
//!
//! **False-positive caveats** are documented per predicate. Notably there is *no*
//! per-tick displacement cap: teleport movement (`mana.set_position`, ADR 0020 — how
//! grid games like Snake move) legitimately moves an entity a whole cell in one tick,
//! so a naive "moved no more than speed·dt" check would fire on correct content. A
//! velocity-aware, history-carrying displacement bound is deferred to ADR 0028's
//! follow-ups; the predicates here are deliberately coarse and stateless.

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");
const components = @import("components.zig");
const World = @import("world.zig").World;
const Tilemap = @import("tilemap.zig").Tilemap;

/// Which invariant a `Violation` reports. `describe` gives a stable, human-readable
/// label for logging (the caller supplies the tick and the entity).
pub const Kind = enum {
    /// A `Transform.pos` component was NaN or infinite.
    nonfinite_transform,
    /// A `Health` violated `0 <= current <= max` (or carried a non-finite / negative
    /// bound).
    health_out_of_range,
    /// A component column's sparse/dense/values arrays disagreed — store corruption.
    sparse_set_corrupt,
    /// A `NavAgent` came to rest inside a wall cell of the sim's tilemap.
    nav_agent_in_wall,

    /// A stable, genre-neutral label for this invariant, for logs and test messages.
    pub fn describe(self: Kind) []const u8 {
        return switch (self) {
            .nonfinite_transform => "transform position must be finite (no NaN/inf)",
            .health_out_of_range => "health must satisfy 0 <= current <= max with finite bounds",
            .sparse_set_corrupt => "component column sparse/dense/values must be consistent",
            .nav_agent_in_wall => "a nav agent must not rest inside a wall cell",
        };
    }
};

/// The first invariant violation a `check` pass found. `entity` is the offending
/// handle, or `ecs.Entity.none` for a store-structural failure not tied to one entity.
/// The caller knows the tick and adds it when reporting.
pub const Violation = struct {
    kind: Kind,
    entity: ecs.Entity = ecs.Entity.none,

    /// Format as `"<label> [entity <index>:<generation>]"` for a test/log message.
    pub fn format(self: Violation, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.kind.describe());
        if (!self.entity.eql(ecs.Entity.none)) {
            try writer.print(" [entity {d}:{d}]", .{ self.entity.index, self.entity.generation });
        }
    }
};

/// Run every universal invariant over `world` (and `tilemap`, if the sim has one),
/// returning the **first** violation found, or `null` if all hold. Order is fixed
/// (finiteness, health range, store integrity, nav-in-wall) so a failing sim reports
/// the same violation every run — deterministic, like everything else in the core.
///
/// Guarantees on `null`: every transform is finite, every health is in range, every
/// component column is internally consistent, and — when `tilemap` is non-null — no
/// nav agent rests inside a wall. Pass `null` for `tilemap` when the sim has no grid;
/// the nav-in-wall predicate is then skipped (there is no topology to violate).
pub fn check(world: *const World, tilemap: ?*const Tilemap) ?Violation {
    if (finiteTransforms(world)) |v| return v;
    if (healthInRange(world)) |v| return v;
    if (columnsConsistent(world)) |v| return v;
    if (tilemap) |tm| if (navAgentsOffWalls(world, tm)) |v| return v;
    return null;
}

/// Every `Transform.pos` is a finite number. Guards against a sim writing NaN/inf into
/// a position (a divide-by-zero in steering, an uninitialized read) — a value that
/// hashes stably yet makes the entity unrenderable and every downstream distance test
/// meaningless. No false positives: a correct sim never produces a non-finite position.
pub fn finiteTransforms(world: *const World) ?Violation {
    for (world.transforms.entities(), world.transforms.values.items) |ei, t| {
        if (!(std.math.isFinite(t.pos.x) and std.math.isFinite(t.pos.y) and std.math.isFinite(t.pos.z))) {
            return .{ .kind = .nonfinite_transform, .entity = world.entityAt(ei) };
        }
    }
    return null;
}

/// Every `Health` satisfies `0 <= current <= max`, with both bounds finite and `max`
/// non-negative. Catches under/overflow of hit points that the hash cannot judge as
/// wrong (a stable -5 HP is still nonsense). Genre-neutral: what damage or death *mean*
/// is content's job, but the numeric envelope is universal. False-positive caveat: a
/// game that deliberately used `Health` as a signed counter outside `[0,max]` would
/// trip this — no shipped content does, and such a use belongs in a data component.
pub fn healthInRange(world: *const World) ?Violation {
    for (world.healths.entities(), world.healths.values.items) |ei, h| {
        const ok = std.math.isFinite(h.current) and std.math.isFinite(h.max) and
            h.max >= 0 and h.current >= 0 and h.current <= h.max;
        if (!ok) return .{ .kind = .health_out_of_range, .entity = world.entityAt(ei) };
    }
    return null;
}

/// Every component column — the built-in `SparseSet`s and each registered data column
/// — is internally consistent: `dense` and `values` are the same length, and each
/// dense slot's entity index points back to that slot through `sparse`, and names an
/// allocated slot. This is the ECS store's structural contract (ADR 0004 §2); a break
/// means iteration would read a stale or aliased value. Pure structural check — it
/// cannot false-positive on valid content, only on a genuine storage bug.
pub fn columnsConsistent(world: *const World) ?Violation {
    const slots = world.entities.generations.items.len;
    if (sparseSetCorrupt(components.Transform, &world.transforms, slots)) return storeViolation();
    if (sparseSetCorrupt(components.Velocity, &world.velocities, slots)) return storeViolation();
    if (sparseSetCorrupt(components.Health, &world.healths, slots)) return storeViolation();
    if (sparseSetCorrupt(components.Collider, &world.colliders, slots)) return storeViolation();
    if (sparseSetCorrupt(components.Controller, &world.controllers, slots)) return storeViolation();
    if (sparseSetCorrupt(components.NavAgent, &world.nav_agents, slots)) return storeViolation();
    for (world.data.columns.items) |*col| {
        if (sparseSetCorrupt(f64, col, slots)) return storeViolation();
    }
    return null;
}

fn storeViolation() Violation {
    return .{ .kind = .sparse_set_corrupt, .entity = ecs.Entity.none };
}

/// True if `set`'s sparse/dense/values arrays are inconsistent: unequal dense/values
/// length, an out-of-range dense entity index, or a dense slot whose `sparse` back-
/// pointer does not name it. `slots` bounds a valid entity index.
fn sparseSetCorrupt(comptime T: type, set: *const ecs.SparseSet(T), slots: usize) bool {
    if (set.dense.items.len != set.values.items.len) return true;
    for (set.dense.items, 0..) |ei, slot| {
        if (ei >= slots) return true;
        if (ei >= set.sparse.items.len) return true;
        if (set.sparse.items[ei] != slot) return true;
    }
    return false;
}

/// No `NavAgent` (ADR 0027) rests inside a wall cell of `tm`. A steered agent whose
/// current cell maps to non-walkable static geometry is stuck in a wall — a stable but
/// broken state the hash cannot flag. Only agents whose position maps onto the grid are
/// judged: an agent off the grid maps to no cell and is skipped (it is outside the maze,
/// not embedded in it), as is an agent with no `Transform`. This is exactly the
/// walkability topology `nav` paths over (`Tilemap.isWalkable`), never a parallel map,
/// so a correctly-steered agent never trips it.
pub fn navAgentsOffWalls(world: *const World, tm: *const Tilemap) ?Violation {
    for (world.nav_agents.entities()) |ei| {
        if (!world.transforms.has(ei)) continue;
        const pos = world.transforms.values.items[world.transforms.sparse.items[ei]].pos;
        const cell = tm.worldToCell(pos) orelse continue; // off-grid: not inside a wall
        if (!tm.isWalkable(cell.col, cell.row)) {
            return .{ .kind = .nav_agent_in_wall, .entity = world.entityAt(ei) };
        }
    }
    return null;
}

const testing = std.testing;

test "invariants: a clean world passes every check" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    try w.setHealth(e, .{ .current = 5, .max = 10 });
    try testing.expectEqual(@as(?Violation, null), check(&w, null));
}

test "invariants: a NaN position is caught with the offending entity" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const good = try w.spawn();
    try w.setTransform(good, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    const bad = try w.spawn();
    try w.setTransform(bad, .{ .pos = .{ .x = std.math.nan(f32), .y = 0, .z = 0 } });

    const v = check(&w, null).?;
    try testing.expectEqual(Kind.nonfinite_transform, v.kind);
    try testing.expect(v.entity.eql(bad));
}

test "invariants: an infinite position is also non-finite" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 0, .y = std.math.inf(f32), .z = 0 } });
    try testing.expectEqual(Kind.nonfinite_transform, finiteTransforms(&w).?.kind);
}

test "invariants: health inside [0,max] passes, current above max fails" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setHealth(e, .{ .current = 10, .max = 10 }); // boundary ok
    try testing.expectEqual(@as(?Violation, null), healthInRange(&w));

    try w.setHealth(e, .{ .current = 11, .max = 10 }); // over max
    const v = healthInRange(&w).?;
    try testing.expectEqual(Kind.health_out_of_range, v.kind);
    try testing.expect(v.entity.eql(e));
}

test "invariants: negative current health is caught" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setHealth(e, .{ .current = -1, .max = 10 });
    try testing.expectEqual(Kind.health_out_of_range, healthInRange(&w).?.kind);
}

test "invariants: a populated but valid store is structurally consistent" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    for (0..4) |i| {
        const e = try w.spawn();
        try w.setTransform(e, .{ .pos = .{ .x = @floatFromInt(i), .y = 0, .z = 0 } });
        if (i % 2 == 0) try w.setHealth(e, .{ .current = 1, .max = 1 });
    }
    // Despawn a middle entity to exercise swap-remove, then re-check.
    try w.despawn(w.entityAt(1));
    try testing.expectEqual(@as(?Violation, null), columnsConsistent(&w));
}

test "invariants: a corrupted sparse back-pointer is detected" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    // Break the sparse→dense link by hand, simulating store corruption.
    w.transforms.sparse.items[e.index] = 999;
    try testing.expectEqual(Kind.sparse_set_corrupt, columnsConsistent(&w).?.kind);
}

test "invariants: a nav agent on a walkable cell passes, one in a wall fails" {
    // A 3x3 grid: a wall ring ('#') around one open centre ('.'), cell_size 1.
    const tm: Tilemap = .{
        .cell_size = 1,
        .origin = core.Vec3.zero,
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
            .{ .glyph = '.', .bundle = null },
        },
        .rows = &.{ "###", "#.#", "###" },
    };

    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setNavAgent(e, .{ .speed = 1 });
    // Open centre is cell (1,1) → world (1,1,0): walkable.
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 1, .z = 0 } });
    try testing.expectEqual(@as(?Violation, null), navAgentsOffWalls(&w, &tm));
    try testing.expectEqual(@as(?Violation, null), check(&w, &tm));

    // Move it onto the wall cell (0,0) → world (0,0,0): inside a wall.
    try w.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    const v = navAgentsOffWalls(&w, &tm).?;
    try testing.expectEqual(Kind.nav_agent_in_wall, v.kind);
    try testing.expect(v.entity.eql(e));
}

test "invariants: an off-grid nav agent is not judged in-wall" {
    const tm: Tilemap = .{ .cell_size = 1, .rows = &.{"."} };
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setNavAgent(e, .{ .speed = 1 });
    try w.setTransform(e, .{ .pos = .{ .x = 100, .y = 100, .z = 0 } }); // way off grid
    try testing.expectEqual(@as(?Violation, null), navAgentsOffWalls(&w, &tm));
}

test "invariants: a violation formats its kind label and offending entity" {
    var buf: [128]u8 = undefined;
    const with_entity = try std.fmt.bufPrint(&buf, "{f}", .{
        Violation{ .kind = .nonfinite_transform, .entity = .{ .index = 3, .generation = 2 } },
    });
    try testing.expect(std.mem.indexOf(u8, with_entity, "finite") != null);
    try testing.expect(std.mem.indexOf(u8, with_entity, "[entity 3:2]") != null);

    // A store-structural violation carries no entity, so none is printed.
    var buf2: [128]u8 = undefined;
    const structural = try std.fmt.bufPrint(&buf2, "{f}", .{storeViolation()});
    try testing.expect(std.mem.indexOf(u8, structural, "[entity") == null);
}

test "invariants: nav-in-wall is only checked when a tilemap is supplied" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setNavAgent(e, .{ .speed = 1 });
    try w.setTransform(e, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    // No tilemap: the nav predicate is skipped, so a clean world passes.
    try testing.expectEqual(@as(?Violation, null), check(&w, null));
}
