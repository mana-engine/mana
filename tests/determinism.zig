//! Integration + determinism test: load a golden scene fixture into an ECS world,
//! run the movement system a fixed number of steps, and assert a bit-identical
//! state hash. This is the backbone guarantee of the file-driven, deterministic
//! core; if it regresses, either the sim math or the serializer drifted. The pinned
//! hash also equals what `mise run run -- games/sandbox` prints for the shipped
//! scene (the fixture and the sandbox scene are identical).

const std = @import("std");
const core = @import("core");
const engine = @import("engine");

// Must match the headless runner in src/runtime/main.zig.
const tick_steps: u32 = 60;

/// Known-good scene, embedded at compile time so the on-disk golden is locked in.
const scene_src: [:0]const u8 = @embedFile("fixtures/scene_hello.zon");

/// The bit-identical state hash after `tick_steps` movement steps. Update only as a
/// deliberate, reviewed step alongside an intended scene or math change.
const golden_state_hash: u64 = 0x1d5ab580f4a8993a;

fn buildWorld(gpa: std.mem.Allocator) !engine.World {
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);
    return engine.scene.toWorld(gpa, scene);
}

fn run(world: *engine.World) void {
    for (0..tick_steps) |_| engine.systems.movement(world, core.time.default_dt);
}

test "golden scene parses into the expected entities" {
    const gpa = std.testing.allocator;
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    try std.testing.expectEqualStrings("hello", scene.name);
    try std.testing.expectEqual(@as(usize, 3), scene.entities.len);
    try std.testing.expectEqualStrings("player", scene.entities[0].name);
    try std.testing.expect(scene.entities[1].velocity == null); // crate is static
}

test "determinism: fixed inputs ⇒ pinned state hash after N ticks" {
    const gpa = std.testing.allocator;
    var world = try buildWorld(gpa);
    defer world.deinit();
    run(&world);
    try std.testing.expectEqual(golden_state_hash, world.stateHash());
}

test "determinism: two independent runs agree bit-for-bit" {
    const gpa = std.testing.allocator;
    var a = try buildWorld(gpa);
    defer a.deinit();
    var b = try buildWorld(gpa);
    defer b.deinit();
    run(&a);
    run(&b);
    try std.testing.expectEqual(a.stateHash(), b.stateHash());
}
