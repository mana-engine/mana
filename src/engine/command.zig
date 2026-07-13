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
const Bundle = components.Bundle;
const Allocator = std.mem.Allocator;

const Command = union(enum) {
    attach: struct { entity: Entity, bundle: Bundle },
    despawn: Entity,
    set_transform: struct { entity: Entity, value: Transform },
    set_velocity: struct { entity: Entity, value: Velocity },
    /// Write a named data component (ADR 0024). `column` is a resolved data-component
    /// column id (columns are append-only, so an id captured now is valid at flush).
    set_data: struct { entity: Entity, column: usize, value: f64 },
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
    /// queue its components — any built-in set (ADR 0016 `Bundle`) — to attach at
    /// flush (ADR 0003 "resolves next tick").
    pub fn spawn(self: *CommandBuffer, gpa: Allocator, world: *World, bundle: Bundle) !Entity {
        const e = try world.spawn();
        try self.reserved.append(gpa, e);
        try self.commands.append(gpa, .{ .attach = .{ .entity = e, .bundle = bundle } });
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

    /// Queue a deferred write of data-component column `column` on `e` to `value`
    /// (ADR 0024 `mana.set`), applied at flush. `column` must be an already-resolved
    /// id (the host resolves the name before queuing). A stale `e` is dropped at flush.
    pub fn setData(self: *CommandBuffer, gpa: Allocator, e: Entity, column: usize, value: f64) Allocator.Error!void {
        try self.commands.append(gpa, .{ .set_data = .{ .entity = e, .column = column, .value = value } });
    }

    /// Snapshot of the buffer's length, taken before a transactional invocation (a
    /// system call, ADR 0003 §9 / issue #2). Pass the result to `rollback` if the
    /// invocation errors, to discard exactly what it queued and nothing queued
    /// before it.
    pub const Mark = struct {
        commands_len: usize,
        reserved_len: usize,
    };

    /// Mark the current end of the buffer. Cheap: just the two lengths, no copy.
    pub fn mark(self: *const CommandBuffer) Mark {
        return .{ .commands_len = self.commands.items.len, .reserved_len = self.reserved.items.len };
    }

    /// Discard everything queued since `m` was taken: truncates the command list
    /// back to the mark (no allocation — a length shrink, not a resize) and voids
    /// any entity `spawn` reserved since the mark by despawning it in `world`, so a
    /// handle the failed invocation already captured reads as stale rather than
    /// leaking a permanently empty entity. This is the per-invocation transaction
    /// rollback ADR 0003 §9 requires: a failed system/handler call must leave no
    /// trace, and the sim continues with the buffer exactly as it was before the
    /// invocation started. `world` must be the same world the marked commands were
    /// recorded against. Errors: only `error.OutOfMemory`, propagated from freeing
    /// a reserved entity's slot in `world`.
    pub fn rollback(self: *CommandBuffer, world: *World, m: Mark) Allocator.Error!void {
        for (self.reserved.items[m.reserved_len..]) |e| try world.despawn(e);
        self.reserved.shrinkRetainingCapacity(m.reserved_len);
        self.commands.shrinkRetainingCapacity(m.commands_len);
    }

    /// Apply every queued command to `world`, pushing `spawned`/`despawned` events.
    /// Clears the buffer. A set targeting an entity that was despawned this tick is
    /// dropped (InvalidEntity); only allocation failure propagates.
    pub fn flush(self: *CommandBuffer, gpa: Allocator, world: *World, events: *event.Queue) !void {
        for (self.reserved.items) |e| try events.push(gpa, .{ .spawned = e });
        for (self.commands.items) |cmd| switch (cmd) {
            .attach => |a| {
                if (a.bundle.transform) |t| try ignoreInvalid(world.setTransform(a.entity, t));
                if (a.bundle.velocity) |v| try ignoreInvalid(world.setVelocity(a.entity, v));
                if (a.bundle.health) |h| try ignoreInvalid(world.setHealth(a.entity, h));
                if (a.bundle.collider) |c| try ignoreInvalid(world.setCollider(a.entity, c));
                if (a.bundle.nav_agent) |na| try ignoreInvalid(world.setNavAgent(a.entity, na));
                if (a.bundle.appearance) |ap| try ignoreInvalid(world.setAppearance(a.entity, ap));
                if (a.bundle.sprite) |sp| try ignoreInvalid(world.setSprite(a.entity, sp));
                for (a.bundle.data) |nv| try ignoreInvalid(world.setDataByName(a.entity, nv.name, nv.value));
            },
            .set_transform => |s| try ignoreInvalid(world.setTransform(s.entity, s.value)),
            .set_velocity => |s| try ignoreInvalid(world.setVelocity(s.entity, s.value)),
            .set_data => |s| try ignoreInvalid(world.setDataByColumn(s.entity, s.column, s.value)),
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

    const e = try cb.spawn(testing.allocator, &world, .{ .transform = .{ .pos = .{ .x = 5, .y = 0, .z = 0 } } });
    try testing.expect(world.isValid(e)); // handle valid immediately
    try testing.expect(world.getTransform(e) == null); // component not attached yet

    try cb.flush(testing.allocator, &world, &events);
    try testing.expect(world.getTransform(e).?.pos.approxEql(.{ .x = 5, .y = 0, .z = 0 }, 1e-6));
    try testing.expect(events.items()[0] == .spawned);
}

test "command buffer: a spawn bundle attaches every present built-in component at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    // A multi-component prototype-style spawn (ADR 0016): transform + velocity +
    // health all land in one deferred command.
    const e = try cb.spawn(testing.allocator, &world, .{
        .transform = .{ .pos = .{ .x = 1, .y = 2, .z = 3 } },
        .velocity = .{ .v = .{ .x = 4, .y = 5, .z = 6 } },
        .health = .{ .current = 7, .max = 10 },
    });
    try cb.flush(testing.allocator, &world, &events);

    try testing.expect(world.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expect(world.getVelocity(e).?.v.approxEql(.{ .x = 4, .y = 5, .z = 6 }, 1e-6));
    try testing.expectEqual(@as(f32, 7), world.getHealth(e).?.current);
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

test "command buffer: a deferred set_data applies to its column at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();
    // Declare the column up-front (as a scene/prototype would), then resolve its id.
    try world.setDataByName(e, "score", 1);
    const col = world.dataColumn("score").?;

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    try cb.setData(testing.allocator, e, col, 99);
    try testing.expectEqual(@as(?f64, 1), world.getData(e, col)); // not yet applied
    try cb.flush(testing.allocator, &world, &events);
    try testing.expectEqual(@as(?f64, 99), world.getData(e, col)); // applied
}

test "command buffer: a spawn bundle registers and attaches named data components" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const vals = [_]components.NamedValue{.{ .name = "hp", .value = 5 }};
    const e = try cb.spawn(testing.allocator, &world, .{ .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .data = &vals });
    try testing.expect(world.dataColumn("hp") == null); // column not registered until flush
    try cb.flush(testing.allocator, &world, &events);
    try testing.expectEqual(@as(?f64, 5), world.getData(e, world.dataColumn("hp").?));
}

test "command buffer: a spawn bundle attaches a collider at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const e = try cb.spawn(testing.allocator, &world, .{
        .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
        .collider = .{ .shape = .{ .circle = .{ .radius = 2 } }, .is_static = true },
    });
    try testing.expect(world.getCollider(e) == null); // not yet applied
    try cb.flush(testing.allocator, &world, &events);
    try testing.expectEqual(@as(f32, 2), world.getCollider(e).?.shape.circle.radius);
    try testing.expect(world.getCollider(e).?.is_static);
}

test "command buffer: a spawn bundle attaches an appearance at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const e = try cb.spawn(testing.allocator, &world, .{
        .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
        .appearance = .{ .color = .{ 1, 1, 0 }, .size = 0.6 },
    });
    try testing.expect(world.getAppearance(e) == null); // not yet applied
    try cb.flush(testing.allocator, &world, &events);
    try testing.expect(std.mem.eql(f32, &.{ 1, 1, 0 }, &world.getAppearance(e).?.color));
    try testing.expectEqual(@as(f32, 0.6), world.getAppearance(e).?.size);
}

test "command buffer: a spawn bundle attaches an appearance's shape at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const e = try cb.spawn(testing.allocator, &world, .{
        .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
        .appearance = .{ .color = .{ 1, 1, 0 }, .shape = .circle },
    });
    try cb.flush(testing.allocator, &world, &events);
    try testing.expectEqual(@import("gpu").Shape.circle, world.getAppearance(e).?.shape);
}

test "command buffer: a spawn bundle attaches a sprite and default cursor at flush" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    const e = try cb.spawn(testing.allocator, &world, .{
        .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
        .sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp" },
    });
    try testing.expect(world.getSprite(e) == null); // not yet applied
    try cb.flush(testing.allocator, &world, &events);
    try testing.expectEqualStrings("chomp", world.getSprite(e).?.clip);
    try testing.expect(world.getAnimationState(e) != null); // cursor attached alongside
}

test "command buffer: rollback discards only commands queued since the mark" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const e = try world.spawn();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);
    var events: event.Queue = .{};
    defer events.deinit(testing.allocator);

    try cb.setTransform(testing.allocator, e, .{ .pos = .{ .x = 1, .y = 1, .z = 1 } }); // before the mark, kept
    const m = cb.mark();
    try cb.setVelocity(testing.allocator, e, .{ .v = .{ .x = 9, .y = 9, .z = 9 } }); // after the mark, discarded
    try cb.rollback(&world, m);

    try cb.flush(testing.allocator, &world, &events);
    try testing.expect(world.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 1, .z = 1 }, 1e-6));
    try testing.expect(world.getVelocity(e) == null); // rolled back before it ever reached flush
}

test "command buffer: rollback voids an entity reserved via spawn since the mark" {
    var world = World.init(testing.allocator);
    defer world.deinit();

    var cb: CommandBuffer = .{};
    defer cb.deinit(testing.allocator);

    const m = cb.mark();
    const e = try cb.spawn(testing.allocator, &world, .{ .transform = .{ .pos = .{ .x = 5, .y = 0, .z = 0 } } });
    try testing.expect(world.isValid(e)); // reserved immediately, per ADR 0003 "resolves next tick"

    try cb.rollback(&world, m);
    try testing.expect(!world.isValid(e)); // reservation undone: the handle is now stale
}
