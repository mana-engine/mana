//! Integration + determinism test: load a golden scene fixture into a `Sim`, register
//! the engine's full standard system set in the exact order the runner uses, run a
//! fixed number of ticks, and assert a bit-identical state hash. This is the backbone
//! guarantee of the file-driven, deterministic core; if it regresses, either the sim
//! math or the serializer drifted. The pinned hash also equals what `mise run run --
//! games/sandbox` prints for the shipped scene (the fixture and the sandbox scene are
//! identical) — and, because the harness now runs the *whole* set, it doubles as the CI
//! proof that `nav`/`collision` are genuine no-ops on this plain, tilemap- and
//! collider-free scene (the invariant the runner's unconditional registration rests on).

const std = @import("std");
const core = @import("core");
const engine = @import("engine");

// Must match the headless runner in src/runtime/main.zig.
const tick_steps: u32 = 60;

/// Known-good scene, embedded at compile time so the on-disk golden is locked in.
const scene_src: [:0]const u8 = @embedFile("fixtures/scene_hello.zon");

/// The bit-identical state hash after `tick_steps` ticks of the full standard system
/// set. Update only as a deliberate, reviewed step alongside an intended scene or math
/// change. Adding `nav`/`collision` to the harness left it unchanged: both no-op on
/// this tilemap- and collider-free fixture.
const golden_state_hash: u64 = 0x65f2a1949cd9fc40;

/// Build a `Sim` from the golden fixture and register the engine's full standard system
/// set in the exact order the runner does (see runtime `registerStandardSystems`):
/// `nav → movement → collision → regen`. The fixture is a plain scene — no tilemap,
/// nav agents, or colliders — so `nav` and `collision` MUST be no-ops here; running the
/// whole set (not just `movement`+`regen`) is what pins the golden hash *and* proves
/// that no-op invariant in CI, rather than by one-time manual capture. Caller owns the
/// returned `Sim` (`deinit` it).
fn buildSim(gpa: std.mem.Allocator) !engine.Sim {
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);
    var sim = engine.Sim.init(gpa, core.time.default_dt);
    errdefer sim.deinit();
    try engine.scene.load(scene, &sim.world);
    try sim.addSystem(engine.nav.navSystem);
    try sim.addSystem(engine.systems.movementSystem);
    try sim.addSystem(engine.collision.collisionSystem);
    try sim.addSystem(engine.systems.regenSystem);
    return sim;
}

test "golden scene parses into the expected entities" {
    const gpa = std.testing.allocator;
    const scene = try engine.scene.parse(gpa, scene_src);
    defer engine.scene.free(gpa, scene);

    try std.testing.expectEqualStrings("hello", scene.name);
    try std.testing.expectEqual(@as(usize, 3), scene.entities.len);
    try std.testing.expectEqualStrings("player", scene.entities[0].name);
    try std.testing.expect(scene.entities[1].velocity == null); // crate is static
    try std.testing.expect(scene.entities[0].health != null); // player has hp
    try std.testing.expect(scene.entities[1].health == null); // crate has none
}

test "determinism: fixed inputs ⇒ pinned state hash after N ticks" {
    const gpa = std.testing.allocator;
    var sim = try buildSim(gpa);
    defer sim.deinit();
    try sim.run(tick_steps);
    try std.testing.expectEqual(golden_state_hash, sim.stateHash());
}

test "determinism: two independent runs agree bit-for-bit" {
    const gpa = std.testing.allocator;
    var a = try buildSim(gpa);
    defer a.deinit();
    var b = try buildSim(gpa);
    defer b.deinit();
    try a.run(tick_steps);
    try b.run(tick_steps);
    try std.testing.expectEqual(a.stateHash(), b.stateHash());
}
