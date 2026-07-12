//! Scene content: a genre-neutral, ZON-declared list of entities with components
//! (ADR 0004 §6). Each entity record has a `name` and one optional field per
//! built-in component; an omitted field means the entity lacks that component.
//! Parsing is pure (source in, data out); loading populates a `World`. File I/O
//! lives in the runtime.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const ecs = @import("ecs");
const components = @import("components.zig");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One entity as written in a scene file: a name plus whichever components are
/// present. New built-in components appear here as new optional fields.
pub const EntityDef = struct {
    name: []const u8,
    transform: ?components.Transform = null,
    velocity: ?components.Velocity = null,
    health: ?components.Health = null,
    /// Named scalar data components (ADR 0024): game-declared per-entity `f64`
    /// attributes, e.g. `.data = .{ .{ .name = "score", .value = 0 } }`. Empty ⇒ the
    /// entity has no data components. Declaring one here registers its column, which
    /// is what lets a script later `mana.get`/`mana.set` it.
    data: []const components.NamedValue = &.{},
};

/// A named collection of entity definitions — the unit a runtime loads.
pub const Scene = struct {
    name: []const u8,
    entities: []const EntityDef,
};

/// Parse a scene from NUL-terminated ZON `source`. The result owns heap
/// allocations (strings, the entities slice); free with `free`.
pub fn parse(gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!Scene {
    return data.parse(Scene, gpa, source);
}

/// Free a `Scene` returned by `parse`.
pub fn free(gpa: Allocator, scene: Scene) void {
    data.free(gpa, scene);
}

/// Spawn every entity in `scene` into `world`, adding each present component.
pub fn load(scene: Scene, world: *World) World.Error!void {
    for (scene.entities) |def| {
        const e = try world.spawn();
        if (def.transform) |t| try world.setTransform(e, t);
        if (def.velocity) |v| try world.setVelocity(e, v);
        if (def.health) |h| try world.setHealth(e, h);
        for (def.data) |nv| try world.setDataByName(e, nv.name, nv.value);
    }
}

/// Build a fresh `World` from a scene. Caller owns the returned world.
pub fn toWorld(gpa: Allocator, scene: Scene) World.Error!World {
    var world = World.init(gpa);
    errdefer world.deinit();
    try load(scene, &world);
    return world;
}

/// Read `path` (relative to `base`), parse it, and build a fresh `World`. This is
/// the I/O convenience over the pure `parse`/`toWorld`; determinism tests use the
/// pure path instead. Caller owns the returned world.
pub fn loadWorldFromFile(gpa: Allocator, io: Io, base: Io.Dir, path: []const u8) !World {
    const src = try base.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const scene = try parse(gpa, src);
    defer free(gpa, scene);
    return toWorld(gpa, scene);
}

/// Hot-reload policy (ADR 0005 §2, §3): rebuild `world` from `path`, **last-good-
/// wins**. A new world is built first; only on success is the old one replaced. If
/// reading or parsing fails, `world` is left untouched and the error is returned —
/// so a file saved mid-edit never installs a half-loaded or empty world.
pub fn reloadWorldFromFile(gpa: Allocator, io: Io, base: Io.Dir, path: []const u8, world: *World) !void {
    const next = try loadWorldFromFile(gpa, io, base, path);
    world.deinit();
    world.* = next;
}

const testing = std.testing;

test "scene: parse entities with optional components" {
    const src =
        \\.{
        \\    .name = "hello",
        \\    .entities = .{
        \\        .{ .name = "player", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .velocity = .{ .v = .{ .x = 1, .y = 0, .z = 0 } } },
        \\        .{ .name = "crate", .transform = .{ .pos = .{ .x = 2, .y = 1, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expectEqual(@as(usize, 2), scene.entities.len);
    try testing.expect(scene.entities[0].velocity != null);
    try testing.expect(scene.entities[1].velocity == null); // crate has no velocity
}

test "scene: load into a world adds the right components" {
    const src =
        \\.{
        \\    .name = "hello",
        \\    .entities = .{
        \\        .{ .name = "a", .transform = .{ .pos = .{ .x = 1, .y = 2, .z = 0 } }, .velocity = .{ .v = .{ .x = 3, .y = 0, .z = 0 } } },
        \\        .{ .name = "b", .transform = .{ .pos = .{ .x = -1, .y = 0, .z = 3 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    try testing.expectEqual(@as(usize, 2), world.count());
    try testing.expectEqual(@as(usize, 1), world.velocities.count()); // only "a" moves
    try testing.expectEqual(@as(usize, 2), world.transforms.count());
}

test "scene: named data components parse and load into the world's data store" {
    const src =
        \\.{
        \\    .name = "grid",
        \\    .entities = .{
        \\        .{ .name = "player", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .data = .{ .{ .name = "score", .value = 10 }, .{ .name = "energy", .value = 3 } } },
        \\        .{ .name = "wall", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expectEqual(@as(usize, 2), scene.entities[0].data.len);
    try testing.expectEqualStrings("score", scene.entities[0].data[0].name);
    try testing.expectEqual(@as(f64, 10), scene.entities[0].data[0].value);
    try testing.expectEqual(@as(usize, 0), scene.entities[1].data.len); // wall has none

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    // "player" is the first slot (index 0), so its data reads back.
    const player: ecs.Entity = .{ .index = 0, .generation = 0 };
    try testing.expectEqual(@as(?f64, 10), world.getData(player, world.dataColumn("score").?));
    try testing.expectEqual(@as(?f64, 3), world.getData(player, world.dataColumn("energy").?));
    const wall: ecs.Entity = .{ .index = 1, .generation = 0 };
    try testing.expectEqual(@as(?f64, null), world.getData(wall, world.dataColumn("score").?));
}

test "scene: health round-trips through the ZON scene into a world" {
    const src =
        \\.{
        \\    .name = "hp",
        \\    .entities = .{
        \\        .{ .name = "hero", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .health = .{ .current = 40, .max = 100 } },
        \\        .{ .name = "prop", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expect(scene.entities[0].health != null);
    try testing.expect(scene.entities[1].health == null); // prop has no health

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    try testing.expectEqual(@as(usize, 1), world.healths.count()); // only "hero" has hp
    // Entities are spawned in scene order into a fresh world, so "hero" is the
    // first slot: index 0, generation 0.
    const hero: ecs.Entity = .{ .index = 0, .generation = 0 };
    try testing.expectEqual(@as(f32, 40), world.getHealth(hero).?.current);
    try testing.expectEqual(@as(f32, 100), world.getHealth(hero).?.max);
}
