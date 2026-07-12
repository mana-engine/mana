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

    /// Uniform integer in the inclusive range `[min(lo, hi), max(lo, hi)]` (ADR 0022
    /// `mana.random_int`). `lo > hi` is treated as the swapped range rather than an
    /// error, and `lo == hi` always returns that value — either way this draws
    /// exactly one `next()`, so the RNG's advance count never depends on argument
    /// order. Maps the draw with Lemire's multiply-high trick (`next() as u128 *
    /// range, top 64 bits`) instead of modulo, which would bias low results; this
    /// exact formula is the version-stable mapping (locked by test below) — it must
    /// never change without a version bump (ADR 0003 §5).
    pub fn intRange(self: *Rng, lo_in: i64, hi_in: i64) i64 {
        const lo = @min(lo_in, hi_in);
        const hi = @max(lo_in, hi_in);
        const range: u64 = @intCast(@as(i128, hi) - @as(i128, lo) + 1);
        const scaled: u128 = @as(u128, self.next()) * @as(u128, range);
        const offset: u64 = @intCast(scaled >> 64);
        return @intCast(@as(i128, lo) + @as(i128, offset));
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

test "rng: intRange stays within [lo, hi] inclusive over many draws" {
    var r = Rng.init(7);
    var saw_lo = false;
    var saw_hi = false;
    for (0..2000) |_| {
        const v = r.intRange(3, 5);
        try testing.expect(v >= 3 and v <= 5);
        if (v == 3) saw_lo = true;
        if (v == 5) saw_hi = true;
    }
    // Both inclusive endpoints are reachable (a common off-by-one to catch).
    try testing.expect(saw_lo and saw_hi);
}

test "rng: intRange(lo, lo) always returns lo and still advances the state" {
    var r = Rng.init(1);
    const before = r.state;
    try testing.expectEqual(@as(i64, 9), r.intRange(9, 9));
    try testing.expect(r.state != before); // one next() consumed, same as any other call
}

test "rng: intRange with lo > hi uses the swapped range, not an error" {
    var a = Rng.init(99);
    var b = Rng.init(99);
    try testing.expectEqual(a.intRange(10, 2), b.intRange(2, 10));
}

test "rng: intRange same seed yields the same sequence (determinism contract)" {
    var a = Rng.init(2026);
    var b = Rng.init(2026);
    for (0..64) |_| try testing.expectEqual(a.intRange(-50, 50), b.intRange(-50, 50));
}

test "rng: intRange known mapping for seed 0, range [0, 9] (locks the formula)" {
    // splitmix64(0)'s first output is 0xE220A8397B1DCDAF (locked above); intRange
    // must map it through the documented multiply-high formula, not modulo.
    var r = Rng.init(0);
    const first: u64 = 0xE220A8397B1DCDAF;
    const expected: i64 = @intCast((@as(u128, first) * 10) >> 64);
    try testing.expectEqual(expected, r.intRange(0, 9));
}
