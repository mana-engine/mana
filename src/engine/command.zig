//! Command buffer (ADR 0007 §3): systems record deferred, ordered structural
//! changes here instead of mutating the world mid-iteration; the frame applies them
//! at a defined flush point, emitting lifecycle events. This backs scripting's
//! spawn/despawn/set and keeps a despawn from invalidating an in-flight iteration.

const std = @import("std");
const ecs = @import("ecs");
const components = @import("components.zig");
const World = @import("world.zig").World;
const event = @import("event.zig");

const Entity = ecs.Entity;
const Transform = components.Transform;
const Velocity = components.Velocity;
const Allocator = std.mem.Allocator;

const Command = union(enum) {
    attach: struct { entity: Entity, transform: ?Transform, velocity: ?Velocity },
    despawn: Entity,
    set_transform: struct { entity: Entity, value: Transform },
    set_velocity: struct { entity: Entity, value: Velocity },
};

pub const CommandBuffer = struct {
    commands: std.ArrayList(Command) = .empty,
    /// Entities reserved by `spawn` this tick (for `spawned` events at flush).
    reserved: std.ArrayList(Entity) = .empty,

    pub fn deinit(self: *CommandBuffer, gpa: Allocator) void {
        self.commands.deinit(gpa);
        self.reserved.deinit(gpa);
        self.* = undefined;
    }

    /// Reserve a new entity immediately (so callers can reference the handle) and
    /// queue its components to attach at flush (ADR 0003 "resolves next tick").
    pub fn spawn(self: *CommandBuffer, gpa: Allocator, world: *World, transform: ?Transform, velocity: ?Velocity) !Entity {
        const e = try world.spawn();
        try self.reserved.append(gpa, e);
        try self.commands.append(gpa, .{ .attach = .{ .entity = e, .transform = transform, .velocity = velocity } });
        return e;
    }

    pub fn despawn(self: *CommandBuffer, gpa: Allocator, e: Entity) Allocator.Error!void {
        try self.commands.append(gpa, .{ .despawn = e });
    }

    pub fn setTransform(self: *CommandBuffer, gpa: Allocator, e: Entity, value: Transform) Allocator.Error!void {
        try self.commands.append(gpa, .{ .set_transform = .{ .entity = e, .value = value } });
    }

    pub fn setVelocity(self: *CommandBuffer, gpa: Allocator, e: Entity, value: Velocity) Allocator.Error!void {
        try self.commands.append(gpa, .{ .set_velocity = .{ .entity = e, .value = value } });
    }

    /// Apply every queued command to `world`, pushing `spawned`/`despawned` events.
    /// Clears the buffer. A set targeting an entity that was despawned this tick is
    /// dropped (InvalidEntity); only allocation failure propagates.
    pub fn flush(self: *CommandBuffer, gpa: Allocator, world: *World, events: *event.Queue) !void {
        for (self.reserved.items) |e| try events.push(gpa, .{ .spawned = e });
        for (self.commands.items) |cmd| switch (cmd) {
            .attach => |a| {
                if (a.transform) |t| try ignoreInvalid(world.setTransform(a.entity, t));
                if (a.velocity) |v| try ignoreInvalid(world.setVelocity(a.entity, v));
            },
            .set_transform => |s| try ignoreInvalid(world.setTransform(s.entity, s.value)),
            .set_velocity => |s| try ignoreInvalid(world.setVelocity(s.entity, s.value)),
            .despawn => |e| {
                if (world.isValid(e)) {
                    try world.despawn(e);
                    try events.push(gpa, .{ .despawned = e });
                }
            },
        };
        self.commands.clearRetainingCapacity();
        self.reserved.clearRetainingCapacity();
    }
};

/// Drop `error.InvalidEntity` (a stale target), propagate allocation failure.
fn ignoreInvalid(result: World.Error!void) Allocator.Error!void {
    result catch |err| switch (err) {
        error.InvalidEntity => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
}

const testing = std.testing;

test "command buffer: deferred despawn applies at flush, emits event" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    try cb.despawn(testing.allocator, e);
    try testing.expect(world.isValid(e)); // not yet applied
    try cb.flush(testing.allocator, &world, &events);
    try testing.expect(!world.isValid(e)); // applied
    try testing.expectEqual(@as(usize, 1), events.items().len);
    try testing.expect(events.items()[0] == .despawned);
}

test "command buffer: deferred spawn reserves a handle, attaches at flush, emits event" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const e = try cb.spawn(testing.allocator, &world, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } }, null);
    try testing.expect(world.isValid(e)); // handle valid immediately
    try testing.expect(world.getTransform(e) == null); // component not attached yet

    try cb.flush(testing.allocator, &world, &events);
    try testing.expect(world.getTransform(e).?.pos.approxEql(.{ .x = 5, .y = 0, .z = 0 }, 1e-6));
    try testing.expect(events.items()[0] == .spawned);
}

test "command buffer: a set on an entity despawned the same tick is dropped" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    try cb.despawn(testing.allocator, e);
    try cb.setTransform(testing.allocator, e, .{ .pos = .{ .x = 9, .y = 9, .z = 9 } });
    try cb.flush(testing.allocator, &world, &events); // despawn first, then set is dropped
    try testing.expect(!world.isValid(e));
}
