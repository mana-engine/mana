//! Spatial-hash broad phase (ADR 0008). A uniform grid buckets each inserted body by
//! every cell its AABB covers; `candidatePairs` returns every index pair that shares
//! a cell. Because a body is inserted into *all* cells its AABB touches, two bodies
//! whose AABBs overlap always share a cell — so the broad phase never misses a true
//! overlap (cell size affects only how many false candidates the narrow phase must
//! reject, never correctness). Output pairs are sorted and de-duplicated, so they are
//! deterministic regardless of insertion order or hash-bucket iteration order.

const std = @import("std");
const shape = @import("shape.zig");

const Aabb = shape.Aabb;
const Allocator = std.mem.Allocator;

/// An unordered pair of item indices, normalised to `a < b`.
pub const Pair = struct { a: u32, b: u32 };

/// Uniform-grid spatial hash. Insert bodies by index + AABB, then read candidate
/// index pairs. Cell size should be roughly the typical collider diameter; it only
/// tunes performance, never correctness.
pub const SpatialHash = struct {
    const Cell = [2]i32;
    const Bucket = std.ArrayList(u32);

    cell_size: f32,
    buckets: std.AutoHashMapUnmanaged(Cell, Bucket) = .{},

    /// A hash with the given grid `cell_size` (must be > 0).
    pub fn init(cell_size: f32) SpatialHash {
        std.debug.assert(cell_size > 0);
        return .{ .cell_size = cell_size };
    }

    pub fn deinit(self: *SpatialHash, gpa: Allocator) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |bucket| bucket.deinit(gpa);
        self.buckets.deinit(gpa);
        self.* = undefined;
    }

    fn cellCoord(self: *const SpatialHash, v: f32) i32 {
        return @intFromFloat(@floor(v / self.cell_size));
    }

    /// Bucket item `index` into every grid cell its AABB `bounds` covers.
    pub fn insert(self: *SpatialHash, gpa: Allocator, index: u32, bounds: Aabb) Allocator.Error!void {
        const x0 = self.cellCoord(bounds.min.x);
        const x1 = self.cellCoord(bounds.max.x);
        const y0 = self.cellCoord(bounds.min.y);
        const y1 = self.cellCoord(bounds.max.y);
        var cy = y0;
        while (cy <= y1) : (cy += 1) {
            var cx = x0;
            while (cx <= x1) : (cx += 1) {
                const gop = try self.buckets.getOrPut(gpa, .{ cx, cy });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, index);
            }
        }
    }

    /// Every distinct index pair sharing at least one cell, sorted ascending and
    /// de-duplicated. Caller owns the returned slice (`gpa.free`).
    pub fn candidatePairs(self: *const SpatialHash, gpa: Allocator) Allocator.Error![]Pair {
        var list: std.ArrayList(Pair) = .empty;
        errdefer list.deinit(gpa);

        var it = self.buckets.valueIterator();
        while (it.next()) |bucket| {
            const items = bucket.items;
            for (items, 0..) |ai, i| {
                for (items[i + 1 ..]) |bi| {
                    if (ai == bi) continue;
                    const pair: Pair = if (ai < bi) .{ .a = ai, .b = bi } else .{ .a = bi, .b = ai };
                    try list.append(gpa, pair);
                }
            }
        }

        std.mem.sort(Pair, list.items, {}, lessThan);

        // Compact adjacent duplicates (a pair recurs once per shared cell).
        var w: usize = 0;
        for (list.items) |p| {
            if (w == 0 or list.items[w - 1].a != p.a or list.items[w - 1].b != p.b) {
                list.items[w] = p;
                w += 1;
            }
        }
        list.shrinkRetainingCapacity(w);
        return list.toOwnedSlice(gpa);
    }

    fn lessThan(_: void, x: Pair, y: Pair) bool {
        return x.a < y.a or (x.a == y.a and x.b < y.b);
    }
};

const testing = std.testing;

fn box(min_x: f32, min_y: f32, max_x: f32, max_y: f32) Aabb {
    return .{ .min = .{ .x = min_x, .y = min_y }, .max = .{ .x = max_x, .y = max_y } };
}

test "broadphase: overlapping AABBs become a candidate pair" {
    var h = SpatialHash.init(1.0);
    defer h.deinit(testing.allocator);
    try h.insert(testing.allocator, 0, box(0, 0, 1, 1));
    try h.insert(testing.allocator, 1, box(0.5, 0.5, 1.5, 1.5));
    const pairs = try h.candidatePairs(testing.allocator);
    defer testing.allocator.free(pairs);
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqual(Pair{ .a = 0, .b = 1 }, pairs[0]);
}

test "broadphase: distant AABBs are not paired" {
    var h = SpatialHash.init(1.0);
    defer h.deinit(testing.allocator);
    try h.insert(testing.allocator, 0, box(0, 0, 1, 1));
    try h.insert(testing.allocator, 1, box(100, 100, 101, 101));
    const pairs = try h.candidatePairs(testing.allocator);
    defer testing.allocator.free(pairs);
    try testing.expectEqual(@as(usize, 0), pairs.len);
}

test "broadphase: a pair spanning several shared cells is emitted once" {
    var h = SpatialHash.init(1.0);
    defer h.deinit(testing.allocator);
    // Two large, fully overlapping boxes share many cells.
    try h.insert(testing.allocator, 0, box(0, 0, 5, 5));
    try h.insert(testing.allocator, 1, box(0, 0, 5, 5));
    const pairs = try h.candidatePairs(testing.allocator);
    defer testing.allocator.free(pairs);
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqual(Pair{ .a = 0, .b = 1 }, pairs[0]);
}

test "broadphase: output is sorted and normalised regardless of insert order" {
    var h = SpatialHash.init(2.0);
    defer h.deinit(testing.allocator);
    // Three mutually overlapping boxes, inserted out of order.
    try h.insert(testing.allocator, 2, box(0, 0, 1, 1));
    try h.insert(testing.allocator, 0, box(0, 0, 1, 1));
    try h.insert(testing.allocator, 1, box(0, 0, 1, 1));
    const pairs = try h.candidatePairs(testing.allocator);
    defer testing.allocator.free(pairs);
    try testing.expectEqual(@as(usize, 3), pairs.len);
    try testing.expectEqual(Pair{ .a = 0, .b = 1 }, pairs[0]);
    try testing.expectEqual(Pair{ .a = 0, .b = 2 }, pairs[1]);
    try testing.expectEqual(Pair{ .a = 1, .b = 2 }, pairs[2]);
}
