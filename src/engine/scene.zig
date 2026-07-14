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
const tilemap = @import("tilemap.zig");
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
    /// A collider (ADR 0025): the same shape `World.setCollider` accepts (`shape`
    /// circle/capsule, `layers`, `is_static`). Declaring one here lets the entity
    /// participate in the native `collision` system and reach `on_collision_begin`.
    collider: ?components.Collider = null,
    /// Named scalar data components (ADR 0024): game-declared per-entity `f64`
    /// attributes, e.g. `.data = .{ .{ .name = "score", .value = 0 } }`. Empty ⇒ the
    /// entity has no data components. Declaring one here registers its column, which
    /// is what lets a script later `mana.get`/`mana.set` it.
    data: []const components.NamedValue = &.{},
    /// A navigation agent (ADR 0027): declaring one makes the native `nav` system steer
    /// this entity toward its target cell (the `nav_target_col`/`nav_target_row` data
    /// components a script sets). Absent ⇒ the entity is not steered.
    nav_agent: ?components.NavAgent = null,
    /// A render appearance (ADR 0030): the color/size the renderer draws this entity
    /// with. Absent ⇒ the renderer falls back to its palette-by-index default.
    appearance: ?components.Appearance = null,
    /// A sprite reference (ADR 0031): the sheet + clip the textured renderer samples for
    /// this entity. Loading one also attaches a default animation cursor (via
    /// `World.setSprite`). Absent ⇒ the entity is not sprited.
    sprite: ?components.Sprite = null,
    /// A tint + blink cue (issue #128): named override states a script selects via an
    /// existing ADR 0024 data component. Loading one also attaches a default cursor
    /// (via `World.setTintCue`). Absent ⇒ the entity has no tint override.
    tint_cue: ?components.TintCue = null,
};

/// A named collection of entity definitions — the unit a runtime loads.
pub const Scene = struct {
    name: []const u8,
    entities: []const EntityDef,
    /// An optional grid level (ADR 0026): a legend + rows of glyphs the engine
    /// materializes into entities (e.g. wall cells → static colliders) on load. Absent
    /// ⇒ the scene is exactly its `entities` list, byte- and hash-identical to a
    /// pre-tilemap scene.
    tilemap: ?tilemap.Tilemap = null,
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

/// Spawn every entity in `scene` into `world`, adding each present component, then
/// materialize the scene's `tilemap` if it has one (ADR 0026) — grid cells become
/// entities *after* the explicit ones, in a fixed row-major order, so a tilemap-free
/// scene loads (and hashes) exactly as before.
pub fn load(scene: Scene, world: *World) World.Error!void {
    for (scene.entities) |def| {
        const e = try world.spawn();
        if (def.transform) |t| try world.setTransform(e, t);
        if (def.velocity) |v| try world.setVelocity(e, v);
        if (def.health) |h| try world.setHealth(e, h);
        if (def.collider) |c| try world.setCollider(e, c);
        if (def.nav_agent) |na| try world.setNavAgent(e, na);
        if (def.appearance) |a| try world.setAppearance(e, a);
        if (def.sprite) |s| try world.setSprite(e, s);
        if (def.tint_cue) |tc| try world.setTintCue(e, tc);
        for (def.data) |nv| try world.setDataByName(e, nv.name, nv.value);
    }
    if (scene.tilemap) |tm| try tilemap.materialize(tm, world);
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
const collision = @import("collision.zig");
const Sim = @import("sim.zig").Sim;

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

test "scene: a collider parses and, on load, the entity has the expected Collider" {
    const src =
        \\.{
        \\    .name = "arena",
        \\    .entities = .{
        \\        .{ .name = "wall", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .collider = .{ .shape = .{ .circle = .{ .radius = 1.5 } }, .layers = .{ .layer = 2, .mask = 3 }, .is_static = true } },
        \\        .{ .name = "prop", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expect(scene.entities[0].collider != null);
    try testing.expect(scene.entities[1].collider == null); // prop has no collider

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    // Entities are spawned in scene order into a fresh world, so "wall" is the
    // first slot: index 0, generation 0.
    const wall: ecs.Entity = .{ .index = 0, .generation = 0 };
    const c = world.getCollider(wall).?;
    try testing.expectEqual(@as(f32, 1.5), c.shape.circle.radius);
    try testing.expectEqual(@as(u32, 2), c.layers.layer);
    try testing.expectEqual(@as(u32, 3), c.layers.mask);
    try testing.expect(c.is_static);
    const prop: ecs.Entity = .{ .index = 1, .generation = 0 };
    try testing.expect(world.getCollider(prop) == null);
}

test "scene: overlapping data-declared colliders dispatch collision_begin through the sim" {
    const src =
        \\.{
        \\    .name = "arena",
        \\    .entities = .{
        \\        .{ .name = "a", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .collider = .{ .shape = .{ .circle = .{ .radius = 1 } } } },
        \\        .{ .name = "b", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } }, .collider = .{ .shape = .{ .circle = .{ .radius = 1 } } } },
        \\    },
        \\}
    ;
    const parsed = try parse(testing.allocator, src);
    defer free(testing.allocator, parsed);

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try load(parsed, &sim.world);

    const Counter = struct {
        var begins: u32 = 0;
        fn handler(_: *@import("world.zig").World, ev: @import("event.zig").Event) void {
            if (ev == .collision_begin) begins += 1;
        }
    };
    Counter.begins = 0;
    try sim.addSystem(collision.collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    // Content-declared colliders (never touched via World.setCollider directly)
    // participate in the native collision system exactly like code-attached ones.
    try testing.expectEqual(@as(u32, 1), Counter.begins);
}

test "scene: an appearance parses and, on load, the entity has the expected Appearance" {
    const src =
        \\.{
        \\    .name = "arena",
        \\    .entities = .{
        \\        .{ .name = "wall", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .appearance = .{ .color = .{ 0.2, 0.3, 0.9 }, .size = 1.0 } },
        \\        .{ .name = "prop", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expect(scene.entities[0].appearance != null);
    try testing.expect(scene.entities[1].appearance == null); // prop has no appearance

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    const wall: ecs.Entity = .{ .index = 0, .generation = 0 };
    const a = world.getAppearance(wall).?;
    try testing.expect(std.mem.eql(f32, &.{ 0.2, 0.3, 0.9 }, &a.color));
    try testing.expectEqual(@as(f32, 1.0), a.size);
    const prop: ecs.Entity = .{ .index = 1, .generation = 0 };
    try testing.expect(world.getAppearance(prop) == null);
}

test "scene: an appearance's shape parses from ZON and defaults to rect when omitted" {
    const src =
        \\.{
        \\    .name = "arena",
        \\    .entities = .{
        \\        .{ .name = "dot", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .appearance = .{ .color = .{ 1, 1, 1 }, .shape = .circle } },
        \\        .{ .name = "wall", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } }, .appearance = .{ .color = .{ 1, 1, 1 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expectEqual(components.Appearance{ .color = .{ 1, 1, 1 }, .shape = .circle }, scene.entities[0].appearance.?);
    try testing.expectEqual(components.Appearance{ .color = .{ 1, 1, 1 } }, scene.entities[1].appearance.?); // shape omitted -> .rect
}

test "scene: a sprite parses and, on load, attaches the Sprite plus a default cursor" {
    const src =
        \\.{
        \\    .name = "arena",
        \\    .entities = .{
        \\        .{ .name = "pac", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp", .loop = .ping_pong } },
        \\        .{ .name = "prop", .transform = .{ .pos = .{ .x = 1, .y = 0, .z = 0 } } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expectEqualStrings("sprites/pac.msf", scene.entities[0].sprite.?.sheet);
    try testing.expectEqual(components.LoopMode.ping_pong, scene.entities[0].sprite.?.loop);
    try testing.expect(scene.entities[1].sprite == null);

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    const pac: ecs.Entity = .{ .index = 0, .generation = 0 };
    try testing.expectEqualStrings("chomp", world.getSprite(pac).?.clip);
    try testing.expect(world.getAnimationState(pac) != null); // default cursor attached
    const prop: ecs.Entity = .{ .index = 1, .generation = 0 };
    try testing.expect(world.getSprite(prop) == null);
    try testing.expect(world.getAnimationState(prop) == null);
}

test "scene: a tilemap parses and materializes wall colliders on load" {
    // A scene with no explicit entities and a small ring-of-walls tilemap. The maze
    // layout is compact grid data (ADR 0026), not one hand-written entity per cell.
    const src =
        \\.{
        \\    .name = "level",
        \\    .entities = .{},
        \\    .tilemap = .{
        \\        .cell_size = 1,
        \\        .origin = .{ .x = 0, .y = 0, .z = 0 },
        \\        .legend = .{
        \\            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
        \\            .{ .glyph = '.', .bundle = null },
        \\        },
        \\        .rows = .{ "###", "#.#", "###" },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expect(scene.tilemap != null);

    var world = try toWorld(testing.allocator, scene);
    defer world.deinit();
    // 8 wall cells materialize as static colliders; the open centre spawns nothing.
    try testing.expectEqual(@as(usize, 8), world.count());
    try testing.expectEqual(@as(usize, 8), world.colliders.count());
    const first = world.entityAt(0);
    try testing.expect(world.getCollider(first).?.is_static);
}

test "scene: a tilemap-materialized wall participates in native collision through the sim" {
    // Two overlapping collider cells (adjacent, radius 1 each) — proving a tilemap
    // wall reaches collisionSystem/on_collision_begin exactly like a code- or
    // entity-declared collider (ADR 0025's path, reused by ADR 0026).
    const src =
        \\.{
        \\    .name = "level",
        \\    .entities = .{},
        \\    .tilemap = .{
        \\        .cell_size = 1,
        \\        .origin = .{ .x = 0, .y = 0, .z = 0 },
        \\        .legend = .{
        \\            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 1 } } } } },
        \\        },
        \\        .rows = .{ "##" },
        \\    },
        \\}
    ;
    const parsed = try parse(testing.allocator, src);
    defer free(testing.allocator, parsed);

    var sim = Sim.init(testing.allocator, 1.0 / 60.0);
    defer sim.deinit();
    try load(parsed, &sim.world);

    const Counter = struct {
        var begins: u32 = 0;
        fn handler(_: *@import("world.zig").World, ev: @import("event.zig").Event) void {
            if (ev == .collision_begin) begins += 1;
        }
    };
    Counter.begins = 0;
    try sim.addSystem(collision.collisionSystem);
    try sim.addHandler(Counter.handler);
    try sim.tick();
    try testing.expectEqual(@as(u32, 1), Counter.begins);
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
