//! Behavior tests for `World` (kept in a sibling file so `world.zig` stays under the
//! ~500-line soft limit; see the `test { _ = @import("world_test.zig"); }` block at
//! the bottom of `world.zig` for how these get pulled into the compilation).

const std = @import("std");
const core = @import("core");
const components = @import("components.zig");
const World = @import("world.zig").World;

const testing = std.testing;

test "world: spawn, set, get, despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    try w.setVelocity(e, .{ .v = .{ .x = 1, .y = 0, .z = 0 } });
    try testing.expect(w.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(usize, 1), w.count());

    try w.despawn(e);
    try testing.expect(!w.isValid(e));
    try testing.expect(w.getTransform(e) == null);
    try testing.expectEqual(@as(usize, 0), w.count());
}

test "world: health round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setHealth(e, .{ .current = 30, .max = 100 });
    try testing.expectEqual(@as(f32, 30), w.getHealth(e).?.current);
    try testing.expectEqual(@as(f32, 100), w.getHealth(e).?.max);
    try testing.expectEqual(@as(usize, 1), w.healths.count());

    try w.despawn(e);
    try testing.expect(w.getHealth(e) == null);
    try testing.expectEqual(@as(usize, 0), w.healths.count());
}

test "world: controller round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setController(e, .{ .velocity = .{ .x = 3, .y = 4 }, .skin = 0.02 });
    try testing.expect(w.getController(e).?.velocity.approxEql(.{ .x = 3, .y = 4 }, 1e-6));
    try testing.expectEqual(@as(f32, 0.02), w.getController(e).?.skin);
    try testing.expectEqual(@as(usize, 1), w.controllers.count());

    try w.despawn(e);
    try testing.expect(w.getController(e) == null);
    try testing.expectEqual(@as(usize, 0), w.controllers.count());
}

test "world: nav agent round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setNavAgent(e, .{ .speed = 3.5 });
    try testing.expectEqual(@as(f32, 3.5), w.getNavAgent(e).?.speed);
    try testing.expectEqual(@as(usize, 1), w.nav_agents.count());

    try w.despawn(e);
    try testing.expect(w.getNavAgent(e) == null);
    try testing.expectEqual(@as(usize, 0), w.nav_agents.count());
}

test "world: setNavAgent on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setNavAgent(e, .{ .speed = 1 }));
}

test "world: appearance round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setAppearance(e, .{ .color = .{ 1, 0.8, 0 }, .size = 0.5 });
    try testing.expect(std.mem.eql(f32, &.{ 1, 0.8, 0 }, &w.getAppearance(e).?.color));
    try testing.expectEqual(@as(f32, 0.5), w.getAppearance(e).?.size);
    try testing.expectEqual(@as(usize, 1), w.appearances.count());

    try w.despawn(e);
    try testing.expect(w.getAppearance(e) == null);
    try testing.expectEqual(@as(usize, 0), w.appearances.count());
}

test "world: setAppearance on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setAppearance(e, .{ .color = .{ 1, 1, 1 } }));
}

test "world: an appearance does not perturb the state hash (cosmetic, excluded)" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Attaching an Appearance to one world must not change its hash — it is a
    // render-time hint, not authoritative sim state. `shape` (ADR 0030 shape
    // addendum) is part of the same struct and must stay excluded too.
    try with.setAppearance(with.entityAt(0), .{ .color = .{ 0.2, 0.4, 0.9 }, .size = 2, .shape = .circle });
    try testing.expectEqual(without.stateHash(), with.stateHash());
}

test "world: a sprite round-trips, attaches a default cursor, and drops both on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setSprite(e, .{ .sheet = "sprites/pac.msf", .clip = "chomp", .loop = .loop });
    try testing.expectEqualStrings("sprites/pac.msf", w.getSprite(e).?.sheet);
    try testing.expectEqualStrings("chomp", w.getSprite(e).?.clip);
    try testing.expectEqual(components.LoopMode.loop, w.getSprite(e).?.loop);
    // Attaching a sprite also attaches a default animation cursor (frame 0, time 0).
    try testing.expect(w.getAnimationState(e) != null);
    try testing.expectEqual(@as(u16, 0), w.getAnimationState(e).?.frame);
    try testing.expectEqual(@as(usize, 1), w.sprites.count());
    try testing.expectEqual(@as(usize, 1), w.animations.count());

    try w.despawn(e);
    try testing.expect(w.getSprite(e) == null);
    try testing.expect(w.getAnimationState(e) == null);
    try testing.expectEqual(@as(usize, 0), w.sprites.count());
    try testing.expectEqual(@as(usize, 0), w.animations.count());
}

test "world: re-setSprite swaps the clip without rewinding the animation cursor" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.setSprite(e, .{ .sheet = "s.msf", .clip = "walk" });
    // Advance the cursor as the render system would, then swap the clip.
    try w.setAnimationState(e, .{ .time_s = 1.5, .frame = 3 });
    try w.setSprite(e, .{ .sheet = "s.msf", .clip = "run" });
    try testing.expectEqualStrings("run", w.getSprite(e).?.clip);
    // The existing cursor is preserved (a clip swap is not a rewind).
    try testing.expectEqual(@as(u16, 3), w.getAnimationState(e).?.frame);
    try testing.expectEqual(@as(f32, 1.5), w.getAnimationState(e).?.time_s);
}

test "world: setSprite on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setSprite(e, .{ .sheet = "x.msf" }));
    // A rejected setSprite must not leave a dangling animation cursor behind.
    try testing.expectEqual(@as(usize, 0), w.animations.count());
}

test "world: a sprite and its animation cursor do not perturb the state hash (cosmetic, excluded)" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Attaching a Sprite (and thus a cursor) to one world must not change its hash — both
    // are cosmetic, and the cursor is wall-clock-driven, so hashing it would break
    // determinism. Also perturb the cursor's frame to prove the cursor itself is excluded.
    try with.setSprite(with.entityAt(0), .{ .sheet = "sprites/pac.msf", .clip = "chomp" });
    try with.setAnimationState(with.entityAt(0), .{ .time_s = 9.9, .frame = 5 });
    try testing.expectEqual(without.stateHash(), with.stateHash());
}

test "world: a nav agent does not perturb the state hash (steering intent, excluded)" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Attaching a NavAgent to one world must not change its hash — like Velocity and
    // Controller, it is movement intent, not authoritative state.
    try with.setNavAgent(with.entityAt(0), .{ .speed = 9 });
    try testing.expectEqual(without.stateHash(), with.stateHash());
}

test "world: setTransform on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setTransform(e, .{ .pos = core.Vec3.zero }));
}

test "world: setVelocity on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setVelocity(e, .{ .v = core.Vec3.zero }));
}

test "world: setHealth on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setHealth(e, .{ .current = 10, .max = 10 }));
}

test "world: setCollider on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setCollider(e, .{ .shape = .{ .circle = .{ .radius = 1 } } }));
}

test "world: a named data component round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setDataByName(e, "score", 42);
    const col = w.dataColumn("score").?;
    try testing.expectEqual(@as(?f64, 42), w.getData(e, col));

    try w.despawn(e);
    try testing.expect(!w.isValid(e));
    // Column stays registered (append-only), but the entity's value is gone.
    try testing.expectEqual(@as(?f64, null), w.getData(e, col));
    try testing.expect(w.dataColumn("score") != null);
}

test "world: getData is null for an undeclared component and a stale handle" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try testing.expect(w.dataColumn("energy") == null); // never declared

    try w.setDataByName(e, "energy", 5);
    const col = w.dataColumn("energy").?;
    try w.despawn(e); // stale handle now
    try testing.expectEqual(@as(?f64, null), w.getData(e, col));
}

test "world: a stale handle is rejected by the data writers" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setDataByName(e, "hp", 1));
    // A stale set must not have registered a column as a side effect.
    try testing.expect(w.dataColumn("hp") == null);
}

test "world: a data component enters the state hash" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Identical worlds hash equal; adding a data value to one diverges the hash,
    // proving the store is inside the determinism fingerprint.
    try testing.expectEqual(without.stateHash(), with.stateHash());
    try with.setDataByName(with.entityAt(0), "score", 7);
    try testing.expect(without.stateHash() != with.stateHash());
}
