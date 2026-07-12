//! A sparse set storing component values of type `T` keyed by entity index
//! (ADR 0004 §2). A packed dense array holds the values that systems iterate
//! cache-line-friendly; a sparse array maps entity index → dense slot. Add,
//! remove, and lookup are O(1); removal swap-pops the dense array. Generation
//! validation is the `World`'s job — this container keys on raw indices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sparse set of `T`. `nil` marks an absent entry in the sparse array.
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        const nil: u32 = std.math.maxInt(u32);

        /// entity index → dense slot (or `nil`).
        sparse: std.ArrayList(u32) = .empty,
        /// dense slot → entity index (parallel to `values`; enables swap-remove).
        dense: std.ArrayList(u32) = .empty,
        /// dense slot → component value.
        values: std.ArrayList(T) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.sparse.deinit(gpa);
            self.dense.deinit(gpa);
            self.values.deinit(gpa);
            self.* = undefined;
        }

        /// True if entity index `ei` has this component.
        pub fn has(self: *const Self, ei: u32) bool {
            return ei < self.sparse.items.len and self.sparse.items[ei] != nil;
        }

        /// Insert or overwrite the component for entity index `ei`.
        pub fn put(self: *Self, gpa: Allocator, ei: u32, value: T) Allocator.Error!void {
            while (self.sparse.items.len <= ei) try self.sparse.append(gpa, nil);
            const slot = self.sparse.items[ei];
            if (slot != nil) {
                self.values.items[slot] = value;
                return;
            }
            try self.dense.append(gpa, ei);
            errdefer _ = self.dense.pop();
            try self.values.append(gpa, value);
            self.sparse.items[ei] = @intCast(self.dense.items.len - 1);
        }

        /// Pointer to entity `ei`'s component, or null. Invalidated by `put`/`remove`.
        pub fn get(self: *Self, ei: u32) ?*T {
            if (!self.has(ei)) return null;
            return &self.values.items[self.sparse.items[ei]];
        }

        /// Remove entity `ei`'s component (swap-pop). No-op if absent.
        pub fn remove(self: *Self, ei: u32) void {
            if (!self.has(ei)) return;
            const slot = self.sparse.items[ei];
            const moved = self.dense.items[self.dense.items.len - 1];
            self.dense.items[slot] = moved;
            self.values.items[slot] = self.values.items[self.values.items.len - 1];
            self.sparse.items[moved] = slot;
            _ = self.dense.pop();
            _ = self.values.pop();
            self.sparse.items[ei] = nil;
        }

        /// Number of entities holding this component.
        pub fn count(self: *const Self) usize {
            return self.values.items.len;
        }

        /// The dense component values, in internal order (for system iteration).
        pub fn slice(self: *Self) []T {
            return self.values.items;
        }

        /// The entity indices parallel to `slice()`.
        pub fn entities(self: *const Self) []const u32 {
            return self.dense.items;
        }
    };
}

const testing = std.testing;

test "sparse set: put/has/get" {
    var s: SparseSet(i32) = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 3, 30);
    try s.put(testing.allocator, 0, 10);
    try testing.expect(s.has(3) and s.has(0) and !s.has(1));
    try testing.expectEqual(@as(i32, 30), s.get(3).?.*);
    try testing.expectEqual(@as(usize, 2), s.count());
}

test "sparse set: put overwrites in place" {
    var s: SparseSet(i32) = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 5, 1);
    try s.put(testing.allocator, 5, 2);
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqual(@as(i32, 2), s.get(5).?.*);
}

test "sparse set: swap-remove keeps the rest intact" {
    var s: SparseSet(i32) = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 1, 11);
    try s.put(testing.allocator, 2, 22);
    try s.put(testing.allocator, 3, 33);
    s.remove(2);
    try testing.expect(!s.has(2));
    try testing.expectEqual(@as(i32, 11), s.get(1).?.*);
    try testing.expectEqual(@as(i32, 33), s.get(3).?.*);
    try testing.expectEqual(@as(usize, 2), s.count());
    s.remove(2); // no-op
    try testing.expectEqual(@as(usize, 2), s.count());
}

test "sparse set: removing the last element" {
    var s: SparseSet(i32) = .{};
    defer s.deinit(testing.allocator);
    try s.put(testing.allocator, 0, 100);
    s.remove(0);
    try testing.expect(!s.has(0));
    try testing.expectEqual(@as(usize, 0), s.count());
}
