//! The opaque entity-handle ABI scripts receive (ADR 0003 §4): a `u32` index +
//! `u32` generation packed into a single 64-bit value — exactly the width of a
//! Lua 5.4 integer, so a handle round-trips through Lua as one opaque number a
//! script may pass back to the engine but never do arithmetic on. Compiled only
//! under `-Denable-lua` (imported by `lua.zig`/`mana.zig`); no `zlua` dependency
//! itself, so this file is plain, dependency-free Zig.
//!
//! Mirrors `ecs.Entity`'s pack/unpack scheme byte-for-byte (generation high,
//! index low) since ADR 0003 §4 pins this bit layout as part of the scripting
//! ABI itself, not merely an `ecs` implementation detail. `script` keeps its own
//! copy here rather than importing `ecs`: the module import DAG (root
//! CLAUDE.md) has `script` depend on `core` only, and the concept the scripting
//! layer owns is "one opaque Lua-integer token", not `ecs`'s live entity
//! storage — a load-bearing-dependency judgment call, not a DRY violation,
//! since both copies are pinned to the same ADR-fixed bit layout and can only
//! drift by a deliberate, reviewed ADR-versioned change to either.

const std = @import("std");

/// An opaque, generational entity reference as seen by Lua. Treat as a token:
/// no arithmetic, no ordering, only equality and `pack`/`unpack`.
pub const Handle = struct {
    index: u32,
    generation: u32,

    /// Pack losslessly into the u64 scripts receive as a Lua integer
    /// (generation high 32 bits, index low 32 bits).
    pub fn pack(h: Handle) u64 {
        return (@as(u64, h.generation) << 32) | @as(u64, h.index);
    }

    /// Inverse of `pack`.
    pub fn unpack(v: u64) Handle {
        return .{ .index = @truncate(v), .generation = @intCast(v >> 32) };
    }

    /// Identity comparison.
    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// The live-entity generation table backing `mana.is_valid` (ADR 0003 §4,
/// §2). One per `script.State`, independent of any `ecs.EntityAllocator` the
/// engine may separately own — nothing in `script` reaches engine/world data
/// (see `mana.zig`'s module doc), so this starts empty and stays empty until a
/// later engine → script wiring task begins mirroring live spawns/despawns
/// into it via `setGeneration`. Until then every handle honestly reads as
/// invalid, which is correct: a `State` with no wiring has no live entities.
pub const Registry = struct {
    /// Current generation per known slot index; unset indices default to `0`
    /// and read as invalid until `setGeneration` records them (index `0` is
    /// a legitimate placeholder, distinguishable from "unseen" only by being
    /// out of range, which `isValid` also checks).
    generations: std.ArrayList(u32) = .empty,

    /// Release the table's backing storage. `gpa` must be the same allocator
    /// used to grow it (the owning `State`'s `Lua` allocator).
    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.generations.deinit(gpa);
        self.* = undefined;
    }

    /// Record that slot `index` is currently live at `generation`. Grows the
    /// table with `0` placeholders for any never-seen lower index. Errors are
    /// allocator failures only.
    pub fn setGeneration(self: *Registry, gpa: std.mem.Allocator, index: u32, generation: u32) !void {
        while (self.generations.items.len <= index) {
            try self.generations.append(gpa, 0);
        }
        self.generations.items[index] = generation;
    }

    /// True if `h`'s generation matches the slot's current live generation. A
    /// stale handle (its entity despawned, generation bumped) or a forged one
    /// (index never registered, or out of range entirely) both read as
    /// `false` — never a crash, never touching anything but this table.
    pub fn isValid(self: *const Registry, h: Handle) bool {
        return h.index < self.generations.items.len and self.generations.items[h.index] == h.generation;
    }
};

const testing = std.testing;

test "handle: pack lays out generation high / index low exactly (ADR 0003 §4 ABI)" {
    // Pin the wire layout to a literal so a silent change to either this or the
    // identical `ecs.Entity` packing (`src/ecs/entity.zig`, same ADR 0003 §4
    // layout, deliberately duplicated per the module import DAG) fails a test.
    const h: Handle = .{ .index = 5, .generation = 10 };
    try testing.expectEqual(@as(u64, 0x0000_000A_0000_0005), h.pack());
    try testing.expect(Handle.unpack(0x0000_000A_0000_0005).eql(h));
}

test "handle: unpack(pack(x)) round-trips across edge and max index/generation" {
    const cases = [_]Handle{
        .{ .index = 0, .generation = 0 },
        .{ .index = 1, .generation = 0 },
        .{ .index = 0, .generation = 1 },
        .{ .index = std.math.maxInt(u32), .generation = 0 },
        .{ .index = 0, .generation = std.math.maxInt(u32) },
        .{ .index = std.math.maxInt(u32), .generation = std.math.maxInt(u32) },
        .{ .index = 12345, .generation = 678 },
        .{ .index = 0x8000_0000, .generation = 0x8000_0001 }, // top bit set in both halves
    };
    for (cases) |h| {
        try testing.expect(Handle.unpack(h.pack()).eql(h));
    }
}

test "handle registry: a freshly-registered handle is valid" {
    var reg: Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.setGeneration(testing.allocator, 3, 0);
    try testing.expect(reg.isValid(.{ .index = 3, .generation = 0 }));
}

test "handle registry: a stale handle is invalid after its slot's generation bumps" {
    var reg: Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.setGeneration(testing.allocator, 3, 0);
    const stale: Handle = .{ .index = 3, .generation = 0 };

    try reg.setGeneration(testing.allocator, 3, 1); // simulates despawn + slot reuse
    try testing.expect(!reg.isValid(stale));
    try testing.expect(reg.isValid(.{ .index = 3, .generation = 1 }));
}

test "handle registry: a forged handle (never-registered index) is invalid" {
    var reg: Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.setGeneration(testing.allocator, 0, 0);
    try testing.expect(!reg.isValid(.{ .index = 999, .generation = 0 }));
    try testing.expect(!reg.isValid(.{ .index = std.math.maxInt(u32), .generation = std.math.maxInt(u32) }));
}
