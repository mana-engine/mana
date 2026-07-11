//! The simulation core: a pure, deterministic, data-oriented state that advances
//! in fixed timesteps. State in, state out — no I/O, no globals. Entity data is
//! stored SoA (parallel arrays) for cache-friendly iteration. Determinism (same
//! seed + inputs ⇒ bit-identical `stateHash` after N ticks) is a tested invariant.

const std = @import("std");
const core = @import("core");

const Vec3 = core.Vec3;
const Allocator = std.mem.Allocator;

/// A minimal simulation: entities with position and constant velocity, integrated
/// each fixed step. This is the seed the ECS and real systems grow from; for now
/// it exists to prove the deterministic fixed-timestep loop end to end.
pub const Sim = struct {
    allocator: Allocator,
    positions: []Vec3,
    velocities: []Vec3,
    tick_count: u64 = 0,

    /// Build a sim from initial entity positions. Velocities are derived
    /// deterministically from `seed` so the state visibly evolves. Caller owns the
    /// result; call `deinit`. Errors only on allocation failure.
    pub fn init(allocator: Allocator, seed: u64, initial_positions: []const Vec3) Allocator.Error!Sim {
        const positions = try allocator.dupe(Vec3, initial_positions);
        errdefer allocator.free(positions);
        const velocities = try allocator.alloc(Vec3, initial_positions.len);

        var rng = core.Rng.init(seed);
        for (velocities) |*v| {
            v.* = .{ .x = rng.signedUnit(), .y = rng.signedUnit(), .z = 0 };
        }
        return .{ .allocator = allocator, .positions = positions, .velocities = velocities };
    }

    /// Release owned arrays.
    pub fn deinit(self: *Sim) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.velocities);
        self.* = undefined;
    }

    /// Advance one fixed step by `dt` seconds. Pure integration; no allocation.
    pub fn tick(self: *Sim, dt: f32) void {
        for (self.positions, self.velocities) |*p, v| {
            p.* = p.add(v.scale(dt));
        }
        self.tick_count += 1;
    }

    /// Advance `steps` fixed steps of `dt` seconds each.
    pub fn run(self: *Sim, steps: u32, dt: f32) void {
        for (0..steps) |_| self.tick(dt);
    }

    /// A stable hash of the observable sim state (entity positions). Same state ⇒
    /// same hash; this is the determinism fingerprint checked in CI.
    pub fn stateHash(self: *const Sim) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.positions));
        return h.final();
    }
};

const testing = std.testing;

const sample_positions = [_]Vec3{
    .{ .x = 0, .y = 0, .z = 0 },
    .{ .x = 2, .y = 1, .z = 0 },
    .{ .x = -3, .y = 4, .z = 1 },
};

test "sim: same seed + inputs ⇒ identical hash after N ticks" {
    const dt = core.time.default_dt;
    var a = try Sim.init(testing.allocator, 1234, &sample_positions);
    defer a.deinit();
    var b = try Sim.init(testing.allocator, 1234, &sample_positions);
    defer b.deinit();

    a.run(60, dt);
    b.run(60, dt);
    try testing.expectEqual(a.stateHash(), b.stateHash());
    try testing.expectEqual(@as(u64, 60), a.tick_count);
}

test "sim: state actually evolves (hash changes after ticking)" {
    const dt = core.time.default_dt;
    var s = try Sim.init(testing.allocator, 1234, &sample_positions);
    defer s.deinit();
    const before = s.stateHash();
    s.run(60, dt);
    try testing.expect(before != s.stateHash());
}

test "sim: different seeds ⇒ different trajectories" {
    const dt = core.time.default_dt;
    var a = try Sim.init(testing.allocator, 1, &sample_positions);
    defer a.deinit();
    var b = try Sim.init(testing.allocator, 2, &sample_positions);
    defer b.deinit();
    a.run(60, dt);
    b.run(60, dt);
    try testing.expect(a.stateHash() != b.stateHash());
}
