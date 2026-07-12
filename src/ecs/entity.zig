//! Generational entity handle and its allocator. A handle is an (index,
//! generation) pair: the index addresses a slot, the generation detects reuse so a
//! stale handle (entity despawned, slot recycled) is rejected instead of aliasing a
//! new entity. The u64 packing is the ABI the scripting layer hands to Lua
//! (ADR 0003 §4) — it lives only here and changes only with a scripting-API bump.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An opaque, generational reference to an entity. Treat as a token: no arithmetic.
pub const Entity = struct {
    index: u32,
    generation: u32,

    /// Sentinel "no entity" value.
    pub const none: Entity = .{ .index = std.math.maxInt(u32), .generation = 0 };

    /// Pack losslessly into a u64 (generation high, index low) — the scripting ABI.
    pub fn pack(e: Entity) u64 {
        return (@as(u64, e.generation) << 32) | @as(u64, e.index);
    }

    /// Inverse of `pack`.
    pub fn unpack(v: u64) Entity {
        return .{ .index = @truncate(v), .generation = @intCast(v >> 32) };
    }

    /// Identity comparison.
    pub fn eql(a: Entity, b: Entity) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Allocates entity slots with a free list and per-slot generations. Deterministic:
/// the same allocate/free sequence yields the same handles on every run.
pub const EntityAllocator = struct {
    /// Current generation per slot index.
    generations: std.ArrayList(u32) = .empty,
    /// Recycled slot indices, LIFO.
    free: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *EntityAllocator, gpa: Allocator) void {
        self.generations.deinit(gpa);
        self.free.deinit(gpa);
        self.* = undefined;
    }

    /// Allocate a live entity, reusing a freed slot when available. The returned
    /// handle carries the slot's current generation.
    pub fn alloc(self: *EntityAllocator, gpa: Allocator) Allocator.Error!Entity {
        if (self.free.pop()) |index| {
            return .{ .index = index, .generation = self.generations.items[index] };
        }
        const index: u32 = @intCast(self.generations.items.len);
        try self.generations.append(gpa, 0);
        return .{ .index = index, .generation = 0 };
    }

    /// Free a live entity's slot, bumping its generation so existing handles to it
    /// become invalid. No-op on a stale handle.
    pub fn free_entity(self: *EntityAllocator, gpa: Allocator, e: Entity) Allocator.Error!void {
        if (!self.isValid(e)) return;
        self.generations.items[e.index] +%= 1;
        try self.free.append(gpa, e.index);
    }

    /// True if `e` refers to the currently-live occupant of its slot.
    pub fn isValid(self: *const EntityAllocator, e: Entity) bool {
        return e.index < self.generations.items.len and
            self.generations.items[e.index] == e.generation;
    }

    /// Number of currently-live entities (allocated slots minus freed ones).
    pub fn liveCount(self: *const EntityAllocator) usize {
        return self.generations.items.len - self.free.items.len;
    }
};

const testing = std.testing;

test "entity: pack/unpack round-trips" {
    const e: Entity = .{ .index = 12345, .generation = 678 };
    try testing.expect(Entity.unpack(e.pack()).eql(e));
}

test "entity allocator: fresh handles are valid and distinct" {
    var ea: EntityAllocator = .{};
    defer ea.deinit(testing.allocator);
    const a = try ea.alloc(testing.allocator);
    const b = try ea.alloc(testing.allocator);
    try testing.expect(ea.isValid(a) and ea.isValid(b));
    try testing.expect(!a.eql(b));
}

test "entity allocator: freeing invalidates the old handle; slot reuse bumps generation" {
    var ea: EntityAllocator = .{};
    defer ea.deinit(testing.allocator);
    const a = try ea.alloc(testing.allocator);
    try ea.free_entity(testing.allocator, a);
    try testing.expect(!ea.isValid(a));

    const b = try ea.alloc(testing.allocator); // reuses a's slot
    try testing.expectEqual(a.index, b.index);
    try testing.expect(a.generation != b.generation);
    try testing.expect(ea.isValid(b) and !ea.isValid(a));
}

test "entity allocator: double free is a no-op" {
    var ea: EntityAllocator = .{};
    defer ea.deinit(testing.allocator);
    const a = try ea.alloc(testing.allocator);
    try ea.free_entity(testing.allocator, a);
    try ea.free_entity(testing.allocator, a); // stale -> ignored
    try testing.expectEqual(@as(usize, 1), ea.free.items.len);
}
