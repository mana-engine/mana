//! Fixed-timestep helpers. The simulation advances in fixed dt increments so it is
//! deterministic and independent of frame rate; the platform layer feeds real
//! elapsed time and drains whole steps. Pure data + arithmetic, no clocks here.

const std = @import("std");

/// The canonical simulation tick rate: 60 steps per second.
pub const default_hz: u32 = 60;

/// Seconds per simulation step at `default_hz`.
pub const default_dt: f32 = 1.0 / @as(f32, @floatFromInt(default_hz));

/// Accumulates real elapsed time and hands back whole fixed steps to run.
pub const FixedTimestep = struct {
    /// Seconds per step.
    dt: f32,
    /// Unconsumed time carried between frames.
    accumulator: f32 = 0,

    /// A stepper at the given rate (Hz must be non-zero).
    pub fn init(hz: u32) FixedTimestep {
        return .{ .dt = 1.0 / @as(f32, @floatFromInt(hz)) };
    }

    /// Add real elapsed seconds and return how many fixed steps are now due,
    /// leaving the remainder in `accumulator`. `elapsed` must be non-negative.
    pub fn advance(self: *FixedTimestep, elapsed: f32) u32 {
        self.accumulator += elapsed;
        var steps: u32 = 0;
        while (self.accumulator >= self.dt) : (self.accumulator -= self.dt) {
            steps += 1;
        }
        return steps;
    }
};

const testing = std.testing;

test "time: default dt is 1/60" {
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), default_dt, 1e-9);
}

test "time: accumulator yields whole steps and keeps remainder" {
    var ts = FixedTimestep.init(60);
    // 2.5 steps worth of time -> 2 steps, half a step remaining.
    try testing.expectEqual(@as(u32, 2), ts.advance(ts.dt * 2.5));
    try testing.expectApproxEqAbs(ts.dt * 0.5, ts.accumulator, 1e-6);
    // Adding another full step's worth crosses the threshold -> 1 step.
    try testing.expectEqual(@as(u32, 1), ts.advance(ts.dt * 0.6));
}
