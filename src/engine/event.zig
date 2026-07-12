//! Engine events (ADR 0007 §4): a typed queue the frame drains and dispatches to
//! handlers. v1 emits lifecycle events from the command-buffer flush; physics and
//! scripting add richer events (collision_begin, hit, death, room_enter) later.

const std = @import("std");
const ecs = @import("ecs");

const Entity = ecs.Entity;
const Allocator = std.mem.Allocator;

/// Something that happened this tick, dispatched to handlers after the command
/// buffer flushes. Grows as physics/scripting need it. (The handler type lives in
/// `sim.zig`, which has the `World` a handler reacts to.)
pub const Event = union(enum) {
    spawned: Entity,
    despawned: Entity,
    /// Two colliders were found overlapping this tick by the collision system
    /// (physics, ADR 0008). `a`/`b` are the involved entities; the ordering is
    /// deterministic for a given world state.
    collision_begin: struct { a: Entity, b: Entity },
};

/// FIFO of events for one tick. Cleared after dispatch.
pub const Queue = struct {
    events: std.ArrayList(Event) = .empty,

    pub fn deinit(self: *Queue, gpa: Allocator) void {
        self.events.deinit(gpa);
        self.* = undefined;
    }

    pub fn push(self: *Queue, gpa: Allocator, event: Event) Allocator.Error!void {
        try self.events.append(gpa, event);
    }

    pub fn items(self: *const Queue) []const Event {
        return self.events.items;
    }

    pub fn clear(self: *Queue) void {
        self.events.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "event queue: push, read, clear" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);
    try q.push(testing.allocator, .{ .spawned = .{ .index = 1, .generation = 0 } });
    try q.push(testing.allocator, .{ .despawned = .{ .index = 1, .generation = 0 } });
    try testing.expectEqual(@as(usize, 2), q.items().len);
    try testing.expect(q.items()[0] == .spawned);
    q.clear();
    try testing.expectEqual(@as(usize, 0), q.items().len);
}
