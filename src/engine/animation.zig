//! Sprite-animation timing (ADR 0031): the pure, GPU-free logic that turns a clip's
//! length + rate + loop mode + elapsed seconds into which position in the clip's frame
//! list is showing. This is the load-bearing cosmetic computation the render-time system
//! (a follow-up lane) calls each frame with WALL-CLOCK elapsed time, writing the result
//! into `AnimationState.frame`; the renderer then samples the sheet frame `clip.frames[
//! pos]`. Kept pure and deterministic-given-time so it is unit-testable in CI without a
//! GPU, exactly like `render.project`.
//!
//! It is deliberately excluded from the state hash's concerns: it takes real elapsed time
//! and never touches the `World`, so nothing here can perturb determinism (ADR 0031 §1;
//! the physics/VFX invariant: "cosmetic and excluded from the state hash").

const std = @import("std");
const components = @import("components.zig");

const LoopMode = components.LoopMode;

/// Resolve which position in a clip's frame list is showing at `time_s` seconds into
/// playback, given the clip length `frame_count` and rate `fps`, honoring `loop`:
///
/// - `.loop`      — wrap: `… frame_count-1, 0, 1 …` forever.
/// - `.once`      — advance then hold the last frame (`frame_count-1`) once reached.
/// - `.ping_pong` — bounce: forward to the end, back to the start, repeat, with the end
///   frames visited once per bounce (period `2*frame_count-2`), so no frame stutters.
///
/// Returns a position in `[0, frame_count)`; the caller maps it to a sheet frame index
/// via `clip.frames[pos]`. Total and pure: a zero-length clip or `fps == 0` (a static
/// clip) yields position 0, and a negative `time_s` clamps to position 0. Owns nothing.
pub fn clipPosition(frame_count: usize, fps: u16, loop: LoopMode, time_s: f32) usize {
    if (frame_count == 0 or fps == 0) return 0;
    if (frame_count == 1) return 0;
    if (time_s <= 0) return 0;

    // Raw frame count elapsed; f64 so a long-running clip does not lose integer precision.
    const elapsed = @as(f64, time_s) * @as(f64, @floatFromInt(fps));
    const raw: usize = @intFromFloat(@floor(elapsed));

    return switch (loop) {
        .loop => raw % frame_count,
        .once => @min(raw, frame_count - 1),
        .ping_pong => blk: {
            // Period visits every frame forward then back, without repeating the two
            // endpoints: [0,1,2,3,2,1] for frame_count 4 → period 6 = 2*4-2.
            const period = 2 * frame_count - 2;
            const t = raw % period;
            break :blk if (t < frame_count) t else period - t;
        },
    };
}

const testing = std.testing;

test "animation: loop mode wraps position modulo the clip length" {
    // 4-frame clip at 10 fps: 0.1 s per frame. Table over identity/edge/wrap.
    const Case = struct { time_s: f32, want: usize };
    const cases = [_]Case{
        .{ .time_s = 0.00, .want = 0 }, // start
        .{ .time_s = 0.05, .want = 0 }, // still within frame 0
        .{ .time_s = 0.10, .want = 1 }, // exact boundary → next frame
        .{ .time_s = 0.35, .want = 3 }, // last frame
        .{ .time_s = 0.40, .want = 0 }, // wrap back to 0
        .{ .time_s = 0.55, .want = 1 }, // second lap
    };
    for (cases) |c| try testing.expectEqual(c.want, clipPosition(4, 10, .loop, c.time_s));
}

test "animation: once mode advances then holds the final frame" {
    const Case = struct { time_s: f32, want: usize };
    const cases = [_]Case{
        .{ .time_s = 0.0, .want = 0 },
        .{ .time_s = 0.2, .want = 2 },
        .{ .time_s = 0.3, .want = 3 }, // reaches the end
        .{ .time_s = 9.9, .want = 3 }, // holds it, no wrap
    };
    for (cases) |c| try testing.expectEqual(c.want, clipPosition(4, 10, .once, c.time_s));
}

test "animation: ping_pong bounces without stuttering the endpoints" {
    // 4 frames → the visited sequence is 0,1,2,3,2,1,(0,1,2,3,2,1)… period 6.
    const want = [_]usize{ 0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1 };
    for (want, 0..) |w, i| {
        const time_s: f32 = @as(f32, @floatFromInt(i)) * 0.1 + 0.001; // just past each boundary
        try testing.expectEqual(w, clipPosition(4, 10, .ping_pong, time_s));
    }
}

test "animation: degenerate clips and non-positive time resolve to position 0" {
    try testing.expectEqual(@as(usize, 0), clipPosition(0, 10, .loop, 1.0)); // empty clip
    try testing.expectEqual(@as(usize, 0), clipPosition(4, 0, .loop, 1.0)); // fps 0 (static)
    try testing.expectEqual(@as(usize, 0), clipPosition(1, 10, .loop, 1.0)); // single frame
    try testing.expectEqual(@as(usize, 0), clipPosition(4, 10, .loop, -1.0)); // negative time
    try testing.expectEqual(@as(usize, 0), clipPosition(4, 10, .ping_pong, 0.0)); // t=0 endpoint
}
