//! The `collision` frame system (ADR 0008): a registerable `engine.Sim` system that
//! finds overlapping colliders each tick and enqueues a `collision_begin` event per
//! overlapping pair. It composes the `physics` port (colliders, spatial-hash broad
//! phase, overlap tests) with the ECS `World`: iterate entities with `Transform` +
//! `Collider`, place each collider at its transform, cull with the broad phase, then
//! confirm with narrow-phase overlap and layer filtering.
//!
//! Deterministic (sim-side): entities are visited in collider-insertion order,
//! broad-phase candidate pairs are sorted, so identical world state yields identical
//! events. **Level-triggered in v1** — an overlap that persists across ticks emits a
//! `collision_begin` every tick; true edge semantics (fire once on enter, plus a
//! `collision_end`) need a persistent contact set and are a named ADR 0008 follow-on.

const std = @import("std");
const core = @import("core");
const physics = @import("physics");
const ecs = @import("ecs");
const World = @import("world.zig").World;
const Context = @import("sim.zig").Context;
const SystemError = @import("sim.zig").SystemError;

const Allocator = std.mem.Allocator;
const Entity = ecs.Entity;
const Vec2 = core.Vec2;

/// Frame system: detect collider overlaps this tick and enqueue a `collision_begin`
/// event per overlapping pair. Scratch state (positioned bodies, the spatial hash,
/// the candidate-pair list) is allocated from `ctx.scratch` (issue #153: `Sim`'s
/// reusable per-tick arena, reset — capacity retained — before this system runs;
/// never `init`/`deinit`ed here) and never read after this call returns. Static–
/// static pairs are skipped; layer masks filter the remainder before the
/// narrow-phase test.
pub fn collisionSystem(ctx: *Context) SystemError!void {
    const arena = ctx.scratch;

    const world = ctx.world;
    const indices = world.colliders.entities(); // []const u32, collider-insertion order
    const colliders = world.colliders.slice(); // []Collider, parallel to indices
    if (indices.len < 2) return;

    // Position every collider-bearing entity that also has a transform. The item
    // index into these parallel arrays is what the broad phase pairs.
    const bodies = try arena.alloc(physics.Body, indices.len);
    const ents = try arena.alloc(Entity, indices.len);
    const layers = try arena.alloc(physics.Layers, indices.len);
    const statics = try arena.alloc(bool, indices.len);
    var n: usize = 0;
    for (indices, colliders) |ei, col| {
        const t = world.transforms.get(ei) orelse continue; // needs a transform to place
        bodies[n] = physics.place(col.shape, .{ .x = t.pos.x, .y = t.pos.y });
        ents[n] = world.entityAt(ei);
        layers[n] = col.layers;
        statics[n] = col.is_static;
        n += 1;
    }
    if (n < 2) return;

    var hash = physics.SpatialHash.init(cellSize(bodies[0..n]));
    defer hash.deinit(arena);
    for (0..n) |i| try hash.insert(arena, @intCast(i), physics.Aabb.ofBody(bodies[i]));

    const pairs = try hash.candidatePairs(arena);
    for (pairs) |p| {
        if (statics[p.a] and statics[p.b]) continue; // two walls: no gameplay event
        if (!physics.Layers.canCollide(layers[p.a], layers[p.b])) continue;
        if (!physics.overlap(bodies[p.a], bodies[p.b])) continue;
        try ctx.events.push(ctx.gpa, .{ .collision_begin = .{ .a = ents[p.a], .b = ents[p.b] } });
    }
}

/// Grid cell size for the broad phase: the largest body extent, so a typical body
/// spans about one cell. Only affects how many candidates the narrow phase rejects,
/// never correctness; falls back to 1 when every body is degenerate.
fn cellSize(bodies: []const physics.Body) f32 {
    var max_extent: f32 = 0;
    for (bodies) |b| {
        const box = physics.Aabb.ofBody(b);
        max_extent = @max(max_extent, box.max.x - box.min.x);
        max_extent = @max(max_extent, box.max.y - box.min.y);
    }
    return if (max_extent > 0) max_extent else 1;
}

const testing = std.testing;
const Sim = @import("sim.zig").Sim;
const event = @import("event.zig");

/// Counts `collision_begin` events across a tick (a test event handler). Uses module
/// state because `engine.Sim` handlers are plain function pointers; each test resets
/// it before use.
const Counter = struct {
    var begins: u32 = 0;
    fn handler(_: *World, ev: event.Event) void {
        if (ev == .collision_begin) begins += 1;
    }
};

fn circle(radius: f32) @import("components.zig").Collider {
    return .{ .shape = .{ .circle = .{ .radius = radius } } };
}

test "collision: overlapping circles emit collision_begin through the sim" {
    Counter.begins = 0;
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const a = try sim.world.spawn();
    try sim.world.setTransform(a, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(a, circle(1.0));
    const b = try sim.world.spawn();
    try sim.world.setTransform(b, .{ .pos = .{ .x = 1.0, .y = 0, .z = 0 } }); // centres 1 apart, radii sum 2
    try sim.world.setCollider(b, circle(1.0));

    try sim.addSystem(collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    try testing.expectEqual(@as(u32, 1), Counter.begins);
}

test "collision: separated colliders emit nothing" {
    Counter.begins = 0;
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const a = try sim.world.spawn();
    try sim.world.setTransform(a, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(a, circle(1.0));
    const b = try sim.world.spawn();
    try sim.world.setTransform(b, .{ .pos = .{ .x = 10, .y = 0, .z = 0 } });
    try sim.world.setCollider(b, circle(1.0));

    try sim.addSystem(collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    try testing.expectEqual(@as(u32, 0), Counter.begins);
}

test "collision: movement into a static wall triggers collision_begin" {
    Counter.begins = 0;
    var sim = Sim.init(testing.allocator, 1.0);
    defer sim.deinit();

    // A mover starting clear of a static wall, closing 1 unit per tick. Radii sum
    // to 0.8, so at x=2 (gap 1.0) they are still clear; at x=3 (gap 0) they overlap.
    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setVelocity(mover, .{ .v = .{ .x = 1, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circle(0.4));

    const wall = try sim.world.spawn();
    try sim.world.setTransform(wall, .{ .pos = .{ .x = 3, .y = 0, .z = 0 } });
    try sim.world.setCollider(wall, .{ .shape = .{ .circle = .{ .radius = 0.4 } }, .is_static = true });

    try sim.addSystem(@import("systems.zig").movementSystem); // integrate first
    try sim.addSystem(collisionSystem); // then detect
    try sim.addHandler(Counter.handler);

    try sim.run(2); // x = 1, then 2 — still clear
    try testing.expectEqual(@as(u32, 0), Counter.begins);
    try sim.tick(); // x = 3 — centres coincide, deep overlap
    try testing.expectEqual(@as(u32, 1), Counter.begins);
}

test "collision: layer masks suppress a non-matching pair" {
    Counter.begins = 0;
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const a = try sim.world.spawn();
    try sim.world.setTransform(a, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(a, .{ .shape = .{ .circle = .{ .radius = 1 } }, .layers = .{ .layer = 0b01, .mask = 0b01 } });
    const b = try sim.world.spawn();
    try sim.world.setTransform(b, .{ .pos = .{ .x = 0.5, .y = 0, .z = 0 } }); // overlapping in space
    try sim.world.setCollider(b, .{ .shape = .{ .circle = .{ .radius = 1 } }, .layers = .{ .layer = 0b10, .mask = 0b10 } });

    try sim.addSystem(collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    try testing.expectEqual(@as(u32, 0), Counter.begins); // different layers, filtered out
}

test "collision: two static colliders never generate an event" {
    Counter.begins = 0;
    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();

    const a = try sim.world.spawn();
    try sim.world.setTransform(a, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(a, .{ .shape = .{ .circle = .{ .radius = 1 } }, .is_static = true });
    const b = try sim.world.spawn();
    try sim.world.setTransform(b, .{ .pos = .{ .x = 0.5, .y = 0, .z = 0 } });
    try sim.world.setCollider(b, .{ .shape = .{ .circle = .{ .radius = 1 } }, .is_static = true });

    try sim.addSystem(collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    try testing.expectEqual(@as(u32, 0), Counter.begins);
}
