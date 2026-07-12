//! Integration test for hot reload (ADR 0005): a `data.Watcher` detects edits to a
//! scene file, and `engine.scene.reloadWorldFromFile` rebuilds the world last-good-
//! wins. Drives real files in a temp dir headlessly — no `--watch` loop needed.

const std = @import("std");
const engine = @import("engine");
const data = @import("data");

const one_entity =
    \\.{ .name = "s", .entities = .{
    \\    .{ .name = "a", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } },
    \\} }
;
const two_entities =
    \\.{ .name = "s", .entities = .{
    \\    .{ .name = "a", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } },
    \\    .{ .name = "b", .transform = .{ .pos = .{ .x = 1, .y = 1, .z = 0 } } },
    \\} }
;
const broken = ".{ .name = "; // truncated — a parse error

test "hot reload: edit rebuilds the world; a broken file keeps the last good one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = one_entity });

    var watcher = data.Watcher.init(gpa, tmp.dir);
    defer watcher.deinit();
    try watcher.add(io, "scene.zon");

    var world = try engine.scene.loadWorldFromFile(gpa, io, tmp.dir, "scene.zon");
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 1), world.count());
    try std.testing.expect(!watcher.poll(io));

    // Edit the file: the watcher notices and the reload picks up the new entity.
    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = two_entities });
    try std.testing.expect(watcher.poll(io));
    try engine.scene.reloadWorldFromFile(gpa, io, tmp.dir, "scene.zon", &world);
    try std.testing.expectEqual(@as(usize, 2), world.count());

    // Save a broken file: the watcher notices, the reload errors, and the world is
    // left exactly as it was (last-good-wins).
    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = broken });
    try std.testing.expect(watcher.poll(io));
    try std.testing.expectError(
        error.ParseZon,
        engine.scene.reloadWorldFromFile(gpa, io, tmp.dir, "scene.zon", &world),
    );
    try std.testing.expectEqual(@as(usize, 2), world.count()); // unchanged
}
