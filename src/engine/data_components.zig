//! Named scalar data components (ADR 0024): the store behind `mana.get`/`mana.set`.
//! A data component is a game-declared per-entity `f64` attribute (score, energy, a
//! numeric state tag) that no built-in engine system knows about — the content half
//! of the component schema, as opposed to the built-in spatial components in
//! `components.zig`.
//!
//! Storage is **Option B** (ADR 0024): a fixed, *registered* set of named columns,
//! not a per-entity dynamic map. Each distinct name — declared in scene/prototype ZON
//! `data` — gets one dense `SparseSet(f64)` column keyed by entity index, exactly the
//! SoA shape every built-in component uses, so a column is cache-coherent to iterate
//! and deterministic to hash. Columns are **append-only**: a name is registered once
//! and its column id is stable forever (never removed), so an id resolved during one
//! dispatch is still valid at the next tick's command flush.
//!
//! DOD, not a hashmap: this keeps named data inside CLAUDE.md's "plain data in
//! contiguous SoA arrays" invariant. The cost is that a name must be declared in data
//! before a script can `set` it (ADR 0024 tradeoff); runtime-arbitrary keys are a
//! future ADR behind the same seam.

const std = @import("std");
const ecs = @import("ecs");

const Allocator = std.mem.Allocator;

/// A stable index into the registered columns. Handed out by `register`, valid for
/// the store's lifetime (columns are never removed).
pub const ColumnId = usize;

/// The registered named-column store owned by a `World`. `gpa` (the world's) backs
/// every allocation; call `deinit`.
pub const DataComponents = struct {
    /// column id → owned component name (this store owns the bytes; ZON names are
    /// borrowed only for the `register` call).
    names: std.ArrayList([]const u8) = .empty,
    /// column id → dense `f64` column, parallel to `names`.
    columns: std.ArrayList(ecs.SparseSet(f64)) = .empty,

    /// Free every owned name and column. `gpa` must be the allocator every mutating
    /// call used (the owning `World`'s).
    pub fn deinit(self: *DataComponents, gpa: Allocator) void {
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
        for (self.columns.items) |*c| c.deinit(gpa);
        self.columns.deinit(gpa);
        self.* = undefined;
    }

    /// The column id for `name`, or `null` if never registered. Linear scan: the
    /// declared-name count is small (like the prototype registry, ADR 0016) and scan
    /// order does not affect determinism.
    pub fn columnId(self: *const DataComponents, name: []const u8) ?ColumnId {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    /// Register `name`, returning its (stable) column id. Idempotent: an
    /// already-registered name returns its existing id without allocating. A fresh
    /// name copies the bytes (the store owns them) and appends an empty column.
    /// Errors: `error.OutOfMemory`.
    pub fn register(self: *DataComponents, gpa: Allocator, name: []const u8) Allocator.Error!ColumnId {
        if (self.columnId(name)) |id| return id;
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.names.append(gpa, owned);
        errdefer _ = self.names.pop();
        try self.columns.append(gpa, .{});
        return self.columns.items.len - 1;
    }

    /// Entity index `ei`'s value in column `col`, or `null` if the entity has no value
    /// there (or `col` is out of range). Generation validation is the `World`'s job;
    /// this keys on raw indices, like `SparseSet`.
    pub fn get(self: *DataComponents, col: ColumnId, ei: u32) ?f64 {
        if (col >= self.columns.items.len) return null;
        const p = self.columns.items[col].get(ei) orelse return null;
        return p.*;
    }

    /// Write entity index `ei`'s value in column `col`. `col` must be a valid id
    /// (produced by `register`/`columnId`); columns are append-only so a resolved id
    /// is always in range. Errors: `error.OutOfMemory`.
    pub fn set(self: *DataComponents, gpa: Allocator, col: ColumnId, ei: u32, value: f64) Allocator.Error!void {
        try self.columns.items[col].put(gpa, ei, value);
    }

    /// Drop entity index `ei`'s value from every column (called from `World.despawn`
    /// so a recycled slot never inherits a stale data value). No-op per column the
    /// entity was absent from.
    pub fn removeEntity(self: *DataComponents, ei: u32) void {
        for (self.columns.items) |*c| c.remove(ei);
    }

    /// Fold the store into determinism hash `h`, in a fixed order (ADR 0024): each
    /// column in registration order, its name bytes then dense entity indices then
    /// dense values — the same dense-order fingerprint the built-in columns use. An
    /// **empty** store feeds zero bytes, so a scene with no data components hashes
    /// bit-identically to one built before this store existed.
    pub fn hash(self: *DataComponents, h: *std.hash.Wyhash) void {
        for (self.names.items, self.columns.items) |name, *col| {
            h.update(name);
            h.update(std.mem.sliceAsBytes(col.entities()));
            h.update(std.mem.sliceAsBytes(col.slice()));
        }
    }
};

const testing = std.testing;

test "data components: register is idempotent and ids are stable" {
    var dc: DataComponents = .{};
    defer dc.deinit(testing.allocator);

    const a = try dc.register(testing.allocator, "score");
    const b = try dc.register(testing.allocator, "energy");
    try testing.expectEqual(a, try dc.register(testing.allocator, "score")); // same name → same id
    try testing.expect(a != b);
    try testing.expectEqual(@as(?ColumnId, a), dc.columnId("score"));
    try testing.expectEqual(@as(?ColumnId, null), dc.columnId("missing"));
    try testing.expectEqual(@as(usize, 2), dc.columns.items.len);
}

test "data components: set then get round-trips per entity and column" {
    var dc: DataComponents = .{};
    defer dc.deinit(testing.allocator);

    const score = try dc.register(testing.allocator, "score");
    const energy = try dc.register(testing.allocator, "energy");
    try dc.set(testing.allocator, score, 1, 10);
    try dc.set(testing.allocator, score, 4, 40);
    try dc.set(testing.allocator, energy, 1, 2.5);

    try testing.expectEqual(@as(?f64, 10), dc.get(score, 1));
    try testing.expectEqual(@as(?f64, 40), dc.get(score, 4));
    try testing.expectEqual(@as(?f64, 2.5), dc.get(energy, 1));
    try testing.expectEqual(@as(?f64, null), dc.get(score, 2)); // entity absent from column
    try testing.expectEqual(@as(?f64, null), dc.get(energy, 4)); // absent from this column
}

test "data components: overwriting a value replaces it in place" {
    var dc: DataComponents = .{};
    defer dc.deinit(testing.allocator);
    const col = try dc.register(testing.allocator, "hp");
    try dc.set(testing.allocator, col, 3, 100);
    try dc.set(testing.allocator, col, 3, 55);
    try testing.expectEqual(@as(?f64, 55), dc.get(col, 3));
}

test "data components: removeEntity clears the entity across every column" {
    var dc: DataComponents = .{};
    defer dc.deinit(testing.allocator);
    const a = try dc.register(testing.allocator, "a");
    const b = try dc.register(testing.allocator, "b");
    try dc.set(testing.allocator, a, 7, 1);
    try dc.set(testing.allocator, b, 7, 2);
    try dc.set(testing.allocator, a, 9, 3); // a different entity, must survive

    dc.removeEntity(7);
    try testing.expectEqual(@as(?f64, null), dc.get(a, 7));
    try testing.expectEqual(@as(?f64, null), dc.get(b, 7));
    try testing.expectEqual(@as(?f64, 3), dc.get(a, 9)); // untouched
}

test "data components: an empty store contributes no bytes to the hash" {
    var empty: DataComponents = .{};
    defer empty.deinit(testing.allocator);

    // A Wyhash fed nothing must equal one the empty store 'hashed' — proving a
    // data-component-free world's state hash is bit-identical to before this store.
    var baseline = std.hash.Wyhash.init(0);
    var with_empty = std.hash.Wyhash.init(0);
    empty.hash(&with_empty);
    try testing.expectEqual(baseline.final(), with_empty.final());
}

test "data components: a populated store changes the hash; identical stores agree" {
    var a: DataComponents = .{};
    defer a.deinit(testing.allocator);
    var b: DataComponents = .{};
    defer b.deinit(testing.allocator);

    var empty = std.hash.Wyhash.init(0);
    const empty_hash = empty.final();

    inline for (.{ &a, &b }) |store| {
        const col = try store.register(testing.allocator, "score");
        try store.set(testing.allocator, col, 2, 42);
    }

    var ha = std.hash.Wyhash.init(0);
    var hb = std.hash.Wyhash.init(0);
    a.hash(&ha);
    b.hash(&hb);
    const a_hash = ha.final();
    try testing.expectEqual(a_hash, hb.final()); // identical construction ⇒ identical hash
    try testing.expect(a_hash != empty_hash); // and it is not the empty fingerprint
}
