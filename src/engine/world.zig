//! The `World` composes the ECS primitives into the concrete entity/component store
//! the engine operates on (ADR 0004 §1, §3, §4): a generational entity allocator
//! plus one sparse-set column per built-in component. Component accessors validate
//! the handle's generation before touching a row, so a stale handle can never alias
//! a recycled entity. Deterministic: identical operations yield identical state.

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");
const components = @import("components.zig");

const Transform = components.Transform;
const Velocity = components.Velocity;
const Health = components.Health;
const Entity = ecs.Entity;
const Allocator = std.mem.Allocator;

pub const World = struct {
    /// Errors from component writes: bad handle, or allocation failure.
    pub const Error = error{InvalidEntity} || Allocator.Error;

    gpa: Allocator,
    entities: ecs.EntityAllocator = .{},
    transforms: ecs.SparseSet(Transform) = .{},
    velocities: ecs.SparseSet(Velocity) = .{},
    healths: ecs.SparseSet(Health) = .{},

    /// An empty world. `gpa` owns all component storage; call `deinit`.
    pub fn init(gpa: Allocator) World {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *World) void {
        self.transforms.deinit(self.gpa);
        self.velocities.deinit(self.gpa);
        self.healths.deinit(self.gpa);
        self.entities.deinit(self.gpa);
        self.* = undefined;
    }

    /// Create a live entity.
    pub fn spawn(self: *World) Allocator.Error!Entity {
        return self.entities.alloc(self.gpa);
    }

    /// Destroy an entity and drop all its components. No-op on a stale handle.
    pub fn despawn(self: *World, e: Entity) Allocator.Error!void {
        if (!self.entities.isValid(e)) return;
        self.transforms.remove(e.index);
        self.velocities.remove(e.index);
        self.healths.remove(e.index);
        try self.entities.free_entity(self.gpa, e);
    }

    /// True if `e` is a live handle.
    pub fn isValid(self: *const World, e: Entity) bool {
        return self.entities.isValid(e);
    }

    /// Number of live entities.
    pub fn count(self: *const World) usize {
        return self.entities.liveCount();
    }

    pub fn setTransform(self: *World, e: Entity, t: Transform) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.transforms.put(self.gpa, e.index, t);
    }

    /// Mutable pointer to `e`'s `Transform`, or null if absent/stale. Invalidated by
    /// subsequent component adds/removes.
    pub fn getTransform(self: *World, e: Entity) ?*Transform {
        if (!self.entities.isValid(e)) return null;
        return self.transforms.get(e.index);
    }

    pub fn setVelocity(self: *World, e: Entity, v: Velocity) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.velocities.put(self.gpa, e.index, v);
    }

    pub fn getVelocity(self: *World, e: Entity) ?*Velocity {
        if (!self.entities.isValid(e)) return null;
        return self.velocities.get(e.index);
    }

    pub fn setHealth(self: *World, e: Entity, h: Health) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.healths.put(self.gpa, e.index, h);
    }

    /// Mutable pointer to `e`'s `Health`, or null if absent/stale. Invalidated by
    /// subsequent component adds/removes.
    pub fn getHealth(self: *World, e: Entity) ?*Health {
        if (!self.entities.isValid(e)) return null;
        return self.healths.get(e.index);
    }

    /// Stable hash of observable state (entity transforms and healths). Same state ⇒
    /// same hash; this is the determinism fingerprint checked in CI. Covering the
    /// health column keeps the regen system's output inside the guarantee.
    pub fn stateHash(self: *World) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.transforms.entities()));
        h.update(std.mem.sliceAsBytes(self.transforms.slice()));
        h.update(std.mem.sliceAsBytes(self.healths.entities()));
        h.update(std.mem.sliceAsBytes(self.healths.slice()));
        return h.final();
    }
};

const testing = std.testing;

test "world: spawn, set, get, despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    try w.setVelocity(e, .{ .v = .{ .x = 1, .y = 0, .z = 0 } });
    try testing.expect(w.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(usize, 1), w.count());

    try w.despawn(e);
    try testing.expect(!w.isValid(e));
    try testing.expect(w.getTransform(e) == null);
    try testing.expectEqual(@as(usize, 0), w.count());
}

test "world: health round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setHealth(e, .{ .current = 30, .max = 100 });
    try testing.expectEqual(@as(f32, 30), w.getHealth(e).?.current);
    try testing.expectEqual(@as(f32, 100), w.getHealth(e).?.max);
    try testing.expectEqual(@as(usize, 1), w.healths.count());

    try w.despawn(e);
    try testing.expect(w.getHealth(e) == null);
    try testing.expectEqual(@as(usize, 0), w.healths.count());
}

test "world: stale handle is rejected by writers" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setTransform(e, .{ .pos = core.Vec3.zero }));
}
