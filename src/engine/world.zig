//! The `World` composes the ECS primitives into the concrete entity/component store
//! the engine operates on (ADR 0004 §1, §3, §4): a generational entity allocator
//! plus one sparse-set column per built-in component. Component accessors validate
//! the handle's generation before touching a row, so a stale handle can never alias
//! a recycled entity. Deterministic: identical operations yield identical state.

const std = @import("std");
const core = @import("core");
const ecs = @import("ecs");
const components = @import("components.zig");
const data_components = @import("data_components.zig");

const Transform = components.Transform;
const Velocity = components.Velocity;
const Health = components.Health;
const Collider = components.Collider;
const Controller = components.Controller;
const NavAgent = components.NavAgent;
const Appearance = components.Appearance;
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
    colliders: ecs.SparseSet(Collider) = .{},
    controllers: ecs.SparseSet(Controller) = .{},
    /// Navigation agents (ADR 0027): entities the native `nav` system steers toward a
    /// target cell over the scene tilemap. Empty until a scene/prototype declares a
    /// `nav_agent`; excluded from `stateHash` (movement intent, like `Velocity`).
    nav_agents: ecs.SparseSet(NavAgent) = .{},
    /// Render appearances (ADR 0030): color/size the renderer draws an entity with.
    /// Empty until a scene/prototype/tilemap-legend cell declares an `appearance`;
    /// excluded from `stateHash` (cosmetic, never read by sim systems).
    appearances: ecs.SparseSet(Appearance) = .{},
    /// Named scalar data components (ADR 0024): game-declared per-entity `f64`
    /// attributes `mana.get`/`mana.set` read and write. Empty until a scene/prototype
    /// declares a `data` component; part of the state hash (`stateHash`).
    data: data_components.DataComponents = .{},

    /// An empty world. `gpa` owns all component storage; call `deinit`.
    pub fn init(gpa: Allocator) World {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *World) void {
        self.transforms.deinit(self.gpa);
        self.velocities.deinit(self.gpa);
        self.healths.deinit(self.gpa);
        self.colliders.deinit(self.gpa);
        self.controllers.deinit(self.gpa);
        self.nav_agents.deinit(self.gpa);
        self.appearances.deinit(self.gpa);
        self.data.deinit(self.gpa);
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
        self.colliders.remove(e.index);
        self.controllers.remove(e.index);
        self.nav_agents.remove(e.index);
        self.appearances.remove(e.index);
        self.data.removeEntity(e.index);
        try self.entities.free_entity(self.gpa, e);
    }

    /// True if `e` is a live handle.
    pub fn isValid(self: *const World, e: Entity) bool {
        return self.entities.isValid(e);
    }

    /// The live handle occupying slot `index` (with its current generation). Only
    /// meaningful for an index known to be live — e.g. one yielded by iterating a
    /// component set, which is how the collision system recovers full handles.
    pub fn entityAt(self: *const World, index: u32) Entity {
        return self.entities.at(index);
    }

    /// Number of live entities.
    pub fn count(self: *const World) usize {
        return self.entities.liveCount();
    }

    /// Attach/overwrite `e`'s `Transform`. Errors: `error.InvalidEntity` for a stale
    /// handle, `error.OutOfMemory` on allocation failure.
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

    /// Attach/overwrite `e`'s `Velocity`. Errors: `error.InvalidEntity` for a stale
    /// handle, `error.OutOfMemory` on allocation failure.
    pub fn setVelocity(self: *World, e: Entity, v: Velocity) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.velocities.put(self.gpa, e.index, v);
    }

    pub fn getVelocity(self: *World, e: Entity) ?*Velocity {
        if (!self.entities.isValid(e)) return null;
        return self.velocities.get(e.index);
    }

    /// Attach/overwrite `e`'s `Health`. Errors: `error.InvalidEntity` for a stale
    /// handle, `error.OutOfMemory` on allocation failure.
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

    /// Attach/overwrite `e`'s `Collider`. Errors: `error.InvalidEntity` for a stale
    /// handle, `error.OutOfMemory` on allocation failure.
    pub fn setCollider(self: *World, e: Entity, c: Collider) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.colliders.put(self.gpa, e.index, c);
    }

    pub fn getCollider(self: *World, e: Entity) ?*Collider {
        if (!self.entities.isValid(e)) return null;
        return self.colliders.get(e.index);
    }

    /// Attach/overwrite `e`'s `Controller` intent. Errors: `error.InvalidEntity` for
    /// a stale handle, `error.OutOfMemory` on allocation failure.
    pub fn setController(self: *World, e: Entity, c: Controller) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.controllers.put(self.gpa, e.index, c);
    }

    /// Mutable pointer to `e`'s `Controller`, or null if absent/stale. Invalidated by
    /// subsequent component adds/removes.
    pub fn getController(self: *World, e: Entity) ?*Controller {
        if (!self.entities.isValid(e)) return null;
        return self.controllers.get(e.index);
    }

    /// Attach/overwrite `e`'s `NavAgent` (ADR 0027). Errors: `error.InvalidEntity` for
    /// a stale handle, `error.OutOfMemory` on allocation failure.
    pub fn setNavAgent(self: *World, e: Entity, na: NavAgent) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.nav_agents.put(self.gpa, e.index, na);
    }

    /// Mutable pointer to `e`'s `NavAgent`, or null if absent/stale. Invalidated by
    /// subsequent component adds/removes.
    pub fn getNavAgent(self: *World, e: Entity) ?*NavAgent {
        if (!self.entities.isValid(e)) return null;
        return self.nav_agents.get(e.index);
    }

    /// Attach/overwrite `e`'s `Appearance` (ADR 0030). Errors: `error.InvalidEntity` for
    /// a stale handle, `error.OutOfMemory` on allocation failure.
    pub fn setAppearance(self: *World, e: Entity, a: Appearance) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.appearances.put(self.gpa, e.index, a);
    }

    /// Mutable pointer to `e`'s `Appearance`, or null if absent/stale. Invalidated by
    /// subsequent component adds/removes.
    pub fn getAppearance(self: *World, e: Entity) ?*Appearance {
        if (!self.entities.isValid(e)) return null;
        return self.appearances.get(e.index);
    }

    /// The column id for the named data component `name` (ADR 0024), or `null` if no
    /// scene/prototype has declared it. `mana.get`/`mana.set` resolve a name to a
    /// column through this; an unknown name is the "undeclared" case.
    pub fn dataColumn(self: *const World, name: []const u8) ?data_components.ColumnId {
        return self.data.columnId(name);
    }

    /// Read `e`'s value in data-component column `col`, or `null` if the handle is
    /// stale, the entity has no value there, or `col` is out of range. Immediate read
    /// backing `mana.get`.
    pub fn getData(self: *World, e: Entity, col: data_components.ColumnId) ?f64 {
        if (!self.entities.isValid(e)) return null;
        return self.data.get(col, e.index);
    }

    /// Write `e`'s value in an already-registered data-component column `col` (ADR
    /// 0024). `col` must come from `dataColumn`/`registerData` (columns are
    /// append-only, so a resolved id stays valid). Backs the deferred `mana.set` at
    /// flush. Errors: `error.InvalidEntity` for a stale handle, `error.OutOfMemory`.
    pub fn setDataByColumn(self: *World, e: Entity, col: data_components.ColumnId, value: f64) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        try self.data.set(self.gpa, col, e.index, value);
    }

    /// Register data component `name` (if new) and write `e`'s value in it — the
    /// declare-and-set path scene load and prototype spawn use (ADR 0024). Validates
    /// the handle *before* registering, so a stale target never grows the column set.
    /// Errors: `error.InvalidEntity` for a stale handle, `error.OutOfMemory`.
    pub fn setDataByName(self: *World, e: Entity, name: []const u8, value: f64) Error!void {
        if (!self.entities.isValid(e)) return error.InvalidEntity;
        const col = try self.data.register(self.gpa, name);
        try self.data.set(self.gpa, col, e.index, value);
    }

    /// Stable hash of observable state (entity transforms and healths). Same state ⇒
    /// same hash; this is the determinism fingerprint checked in CI. Covering the
    /// health column keeps the regen system's output inside the guarantee. Colliders
    /// are read-only sim state (collision only emits events) and stay out of the hash.
    /// `Controller` is likewise excluded: it is input intent (like `Velocity`, also
    /// excluded), not authoritative state — its effect lands in `Transform`, which is
    /// hashed, so the character controller's output stays inside the guarantee.
    /// `NavAgent` (ADR 0027) is excluded for the same reason: steering intent whose
    /// effect lands in the hashed `Transform` (its target lives in hashed data
    /// components), so a scene with no nav agents hashes bit-identically.
    /// `Appearance` (ADR 0030) is excluded too: purely a render-time hint no sim
    /// system reads, so a scene with no declared appearances hashes bit-identically.
    /// Named data components (ADR 0024) are authoritative sim state and are folded in
    /// last, in registration/dense order; an empty store adds zero bytes, so a scene
    /// with no data components hashes bit-identically to before the store existed.
    pub fn stateHash(self: *World) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.transforms.entities()));
        h.update(std.mem.sliceAsBytes(self.transforms.slice()));
        h.update(std.mem.sliceAsBytes(self.healths.entities()));
        h.update(std.mem.sliceAsBytes(self.healths.slice()));
        self.data.hash(&h);
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

test "world: controller round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setController(e, .{ .velocity = .{ .x = 3, .y = 4 }, .skin = 0.02 });
    try testing.expect(w.getController(e).?.velocity.approxEql(.{ .x = 3, .y = 4 }, 1e-6));
    try testing.expectEqual(@as(f32, 0.02), w.getController(e).?.skin);
    try testing.expectEqual(@as(usize, 1), w.controllers.count());

    try w.despawn(e);
    try testing.expect(w.getController(e) == null);
    try testing.expectEqual(@as(usize, 0), w.controllers.count());
}

test "world: nav agent round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setNavAgent(e, .{ .speed = 3.5 });
    try testing.expectEqual(@as(f32, 3.5), w.getNavAgent(e).?.speed);
    try testing.expectEqual(@as(usize, 1), w.nav_agents.count());

    try w.despawn(e);
    try testing.expect(w.getNavAgent(e) == null);
    try testing.expectEqual(@as(usize, 0), w.nav_agents.count());
}

test "world: setNavAgent on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setNavAgent(e, .{ .speed = 1 }));
}

test "world: appearance round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setAppearance(e, .{ .color = .{ 1, 0.8, 0 }, .size = 0.5 });
    try testing.expect(std.mem.eql(f32, &.{ 1, 0.8, 0 }, &w.getAppearance(e).?.color));
    try testing.expectEqual(@as(f32, 0.5), w.getAppearance(e).?.size);
    try testing.expectEqual(@as(usize, 1), w.appearances.count());

    try w.despawn(e);
    try testing.expect(w.getAppearance(e) == null);
    try testing.expectEqual(@as(usize, 0), w.appearances.count());
}

test "world: setAppearance on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setAppearance(e, .{ .color = .{ 1, 1, 1 } }));
}

test "world: an appearance does not perturb the state hash (cosmetic, excluded)" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Attaching an Appearance to one world must not change its hash — it is a
    // render-time hint, not authoritative sim state. `shape` (ADR 0030 shape
    // addendum) is part of the same struct and must stay excluded too.
    try with.setAppearance(with.entityAt(0), .{ .color = .{ 0.2, 0.4, 0.9 }, .size = 2, .shape = .circle });
    try testing.expectEqual(without.stateHash(), with.stateHash());
}

test "world: a nav agent does not perturb the state hash (steering intent, excluded)" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Attaching a NavAgent to one world must not change its hash — like Velocity and
    // Controller, it is movement intent, not authoritative state.
    try with.setNavAgent(with.entityAt(0), .{ .speed = 9 });
    try testing.expectEqual(without.stateHash(), with.stateHash());
}

test "world: setTransform on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setTransform(e, .{ .pos = core.Vec3.zero }));
}

test "world: setVelocity on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setVelocity(e, .{ .v = core.Vec3.zero }));
}

test "world: setHealth on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setHealth(e, .{ .current = 10, .max = 10 }));
}

test "world: setCollider on a stale handle errors" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setCollider(e, .{ .shape = .{ .circle = .{ .radius = 1 } } }));
}

test "world: a named data component round-trips and is dropped on despawn" {
    var w = World.init(testing.allocator);
    defer w.deinit();

    const e = try w.spawn();
    try w.setDataByName(e, "score", 42);
    const col = w.dataColumn("score").?;
    try testing.expectEqual(@as(?f64, 42), w.getData(e, col));

    try w.despawn(e);
    try testing.expect(!w.isValid(e));
    // Column stays registered (append-only), but the entity's value is gone.
    try testing.expectEqual(@as(?f64, null), w.getData(e, col));
    try testing.expect(w.dataColumn("score") != null);
}

test "world: getData is null for an undeclared component and a stale handle" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try testing.expect(w.dataColumn("energy") == null); // never declared

    try w.setDataByName(e, "energy", 5);
    const col = w.dataColumn("energy").?;
    try w.despawn(e); // stale handle now
    try testing.expectEqual(@as(?f64, null), w.getData(e, col));
}

test "world: a stale handle is rejected by the data writers" {
    var w = World.init(testing.allocator);
    defer w.deinit();
    const e = try w.spawn();
    try w.despawn(e);
    try testing.expectError(error.InvalidEntity, w.setDataByName(e, "hp", 1));
    // A stale set must not have registered a column as a side effect.
    try testing.expect(w.dataColumn("hp") == null);
}

test "world: a data component enters the state hash" {
    var with = World.init(testing.allocator);
    defer with.deinit();
    var without = World.init(testing.allocator);
    defer without.deinit();

    inline for (.{ &with, &without }) |wp| {
        const e = try wp.spawn();
        try wp.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    }
    // Identical worlds hash equal; adding a data value to one diverges the hash,
    // proving the store is inside the determinism fingerprint.
    try testing.expectEqual(without.stateHash(), with.stateHash());
    try with.setDataByName(with.entityAt(0), "score", 7);
    try testing.expect(without.stateHash() != with.stateHash());
}
