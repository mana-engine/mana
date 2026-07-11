//! Deterministic, version-stable pseudo-random generator (splitmix64). We roll our
//! own rather than lean on std so the bit-sequence is fixed forever — the
//! determinism guarantee (same seed ⇒ same sim) depends on it never drifting.

const std = @import("std");

/// A seedable splitmix64 generator. Copyable value type; advancing mutates `state`.
pub const Rng = struct {
    state: u64,

    /// Seed the generator. Any seed (including 0) is valid.
    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    /// Next 64-bit value. Advances the state by one step (splitmix64).
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform float in [0, 1) using the top 24 bits (exact for f32).
    pub fn float01(self: *Rng) f32 {
        const bits: u32 = @truncate(self.next() >> 40);
        return @as(f32, @floatFromInt(bits)) * (1.0 / 16777216.0);
    }

    /// Uniform float in [-1, 1).
    pub fn signedUnit(self: *Rng) f32 {
        return self.float01() * 2.0 - 1.0;
    }
};

const testing = std.testing;

test "rng: same seed yields the same sequence" {
    var a = Rng.init(42);
    var b = Rng.init(42);
    for (0..64) |_| try testing.expectEqual(a.next(), b.next());
}

test "rng: different seeds diverge" {
    var a = Rng.init(1);
    var b = Rng.init(2);
    try testing.expect(a.next() != b.next());
}

test "rng: splitmix64 known first output for seed 0" {
    // Locks the algorithm: splitmix64(0) first output is a fixed constant.
    var r = Rng.init(0);
    try testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), r.next());
}

test "rng: float01 stays in [0,1)" {
    var r = Rng.init(12345);
    for (0..1000) |_| {
        const f = r.float01();
        try testing.expect(f >= 0.0 and f < 1.0);
    }
}
