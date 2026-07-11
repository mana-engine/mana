//! Integration + determinism test: load a golden scene fixture, build a sim, and
//! assert that a fixed seed + fixed inputs produce a bit-identical state hash after
//! N ticks. This is the backbone guarantee of the file-driven, deterministic core;
//! if it regresses, either the sim math or the serializer drifted. The pinned hash
//! also equals what `mise run run -- games/sandbox` prints for the shipped scene.

const std = @import("std");
const core = @import("core");
const engine = @import("engine");

// Must match the headless runner in src/runtime/main.zig.
const seed: u64 = 0x5EED;
const tick_steps: u32 = 60;

/// Known-good scene, embedded at compile time so the on-disk golden is locked in.
const scene_src: [:0]const u8 = @embedFile("fixtures/scene_hello.zon");

/// The bit-identical state hash after `tick_steps` fixed steps from `seed`.
/// Update only as a deliberate, reviewed step alongside an intended math change.
const golden_state_hash: u64 = 0x9d73a6b383089f3a;

test "golden scene parses into the expected entities" {
    const gpa = std.testing.allocator;
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    try std.testing.expectEqualStrings("hello", scene.name);
    try std.testing.expectEqual(@as(usize, 3), scene.entities.len);
    try std.testing.expectEqualStrings("player", scene.entities[0].name);
    try std.testing.expect(scene.entities[2].pos.approxEql(.{ .x = -3, .y = 4, .z = 1 }, 1e-6));
}

test "determinism: fixed seed + inputs ⇒ pinned state hash after N ticks" {
    const gpa = std.testing.allocator;
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    var sim = try engine.scene.toSim(gpa, seed, scene);
    defer sim.deinit();
    sim.run(tick_steps, core.time.default_dt);

    try std.testing.expectEqual(golden_state_hash, sim.stateHash());
}

test "determinism: two independent runs agree bit-for-bit" {
    const gpa = std.testing.allocator;
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    var a = try engine.scene.toSim(gpa, seed, scene);
    defer a.deinit();
    var b = try engine.scene.toSim(gpa, seed, scene);
    defer b.deinit();
    a.run(tick_steps, core.time.default_dt);
    b.run(tick_steps, core.time.default_dt);

    try std.testing.expectEqual(a.stateHash(), b.stateHash());
}
