//! Scene content: a genre-neutral, ZON-declared list of entities with components
//! (ADR 0004 §6). Each entity record has a `name` and one optional field per
//! built-in component; an omitted field means the entity lacks that component.
//! Parsing is pure (source in, data out); loading populates a `World`. File I/O
//! lives in the runtime.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const components = @import("components.zig");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// One entity as written in a scene file: a name plus whichever components are
/// present. New built-in components appear here as new optional fields.
pub const EntityDef = struct {
    name: []const u8,
    transform: ?components.Transform = null,
    velocity: ?components.Velocity = null,
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
    }
}

/// Build a fresh `World` from a scene. Caller owns the returned world.
pub fn toWorld(gpa: Allocator, scene: Scene) World.Error!World {
    var world = World.init(gpa);
    errdefer world.deinit();
    try load(scene, &world);
    return world;
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
