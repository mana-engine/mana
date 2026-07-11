//! Scene content: a genre-neutral description of entities placed in the world,
//! loaded from ZON. The engine interprets scenes; it has no notion of any specific
//! game. Parsing is pure (source in, data out); file I/O lives in the runtime.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const sim = @import("sim.zig");

const Vec3 = core.Vec3;
const Allocator = std.mem.Allocator;

/// One placed entity. Grows more components as the engine matures.
pub const Entity = struct {
    name: []const u8,
    pos: Vec3,
};

/// A named collection of entities — the unit a runtime loads and hands to a `Sim`.
pub const Scene = struct {
    name: []const u8,
    entities: []const Entity,
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

/// Build a `Sim` seeded from a scene's entity positions. `seed` drives the
/// deterministic initial velocities. Caller owns the returned `Sim`.
pub fn toSim(gpa: Allocator, seed: u64, scene: Scene) Allocator.Error!sim.Sim {
    const positions = try gpa.alloc(Vec3, scene.entities.len);
    defer gpa.free(positions);
    for (scene.entities, positions) |e, *p| p.* = e.pos;
    return sim.Sim.init(gpa, seed, positions);
}

const testing = std.testing;

test "scene: parse ZON into entities" {
    const src =
        \\.{
        \\    .name = "hello",
        \\    .entities = .{
        \\        .{ .name = "player", .pos = .{ .x = 0, .y = 0, .z = 0 } },
        \\        .{ .name = "crate", .pos = .{ .x = 2, .y = 1, .z = 0 } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);
    try testing.expectEqualStrings("hello", scene.name);
    try testing.expectEqual(@as(usize, 2), scene.entities.len);
    try testing.expectEqualStrings("crate", scene.entities[1].name);
    try testing.expect(scene.entities[1].pos.approxEql(.{ .x = 2, .y = 1, .z = 0 }, 1e-6));
}

test "scene: build a deterministic sim from a scene" {
    const src =
        \\.{
        \\    .name = "hello",
        \\    .entities = .{
        \\        .{ .name = "a", .pos = .{ .x = 1, .y = 2, .z = 0 } },
        \\        .{ .name = "b", .pos = .{ .x = -1, .y = 0, .z = 3 } },
        \\    },
        \\}
    ;
    const scene = try parse(testing.allocator, src);
    defer free(testing.allocator, scene);

    var s = try toSim(testing.allocator, 99, scene);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.positions.len);
    try testing.expect(s.positions[0].approxEql(.{ .x = 1, .y = 2, .z = 0 }, 1e-6));
}
