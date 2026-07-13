//! Tile/grid level data (ADR 0026): a genre-neutral grid resource a scene may carry,
//! materialized into world entities on load. The grid is authored as a `legend`
//! (glyph → the components a cell of that glyph places) plus `rows` of characters —
//! the compact, human-diffable form a maze/level wants. The engine interprets the grid
//! *generically*: it maps each cell's glyph to a legend tile and, for tiles carrying
//! components (e.g. a static `Collider`, ADR 0025), spawns an entity at the cell's world
//! position. No maze/genre concept lives here — what a glyph *means* is content's job
//! (invariant #6). Placement is projection-independent (ADR 0014: the camera decides how
//! a cell *looks*, never where it *is*).

const std = @import("std");
const core = @import("core");
const components = @import("components.zig");
const World = @import("world.zig").World;

const Vec3 = core.Vec3;

/// One legend entry: which components a cell bearing `glyph` materializes. `bundle` is
/// the canonical built-in component set (ADR 0016/0024/0025) placed at each matching
/// cell — the cell supplies the `Transform`, so any `bundle.transform` is ignored
/// (mirroring `prototype.bundleAt`). A null `bundle` (or a glyph absent from the
/// legend) is a walkable/empty cell: nothing is spawned. This is what keeps a grid from
/// spawning an entity per floor cell.
pub const Tile = struct {
    glyph: u8,
    bundle: ?components.Bundle = null,
};

/// A grid level on a scene (ADR 0026): `cell_size` world units per cell, `origin` the
/// world position of cell (col 0, row 0), a glyph `legend`, and `rows` of characters
/// (one string per row, top-to-bottom as written). Rows need not be equal length — a
/// short row simply has fewer cells.
pub const Tilemap = struct {
    /// World units spanned by one cell along each axis.
    cell_size: f32 = 1,
    /// World position of cell (col 0, row 0). Centering a grid is content's choice,
    /// expressed here; the engine imposes no genre convention.
    origin: Vec3 = Vec3.zero,
    /// Glyph → placement mapping. Tiny; scanned linearly. First match wins on a
    /// duplicate glyph.
    legend: []const Tile = &.{},
    /// The grid, one string per row (top-to-bottom). A cell's glyph is `rows[row][col]`.
    rows: []const []const u8 = &.{},

    /// World position of the cell at (`col`, `row`), both 0-based. Column maps to +X,
    /// row maps to +Y, scaled by `cell_size` from `origin`; Z is `origin.z`. Pure,
    /// total, and projection-independent — how the grid is framed on screen is the
    /// camera's job (ADR 0014), never a cell's world placement.
    pub fn cellToWorld(self: Tilemap, col: usize, row: usize) Vec3 {
        return .{
            .x = self.origin.x + @as(f32, @floatFromInt(col)) * self.cell_size,
            .y = self.origin.y + @as(f32, @floatFromInt(row)) * self.cell_size,
            .z = self.origin.z,
        };
    }

    /// The legend tile for `glyph`, or null if the glyph is unmapped (walkable). First
    /// match wins on a duplicate glyph.
    pub fn tileFor(self: Tilemap, glyph: u8) ?Tile {
        for (self.legend) |t| {
            if (t.glyph == glyph) return t;
        }
        return null;
    }
};

/// Materialize `tm` into `world`: for every cell whose glyph maps to a legend tile with
/// a present `bundle`, spawn one entity at the cell's world position carrying that
/// bundle's components (the cell supplies the `Transform`). Walkable cells — an unmapped
/// glyph, or a tile with a null `bundle` — spawn nothing.
///
/// Iteration is row-major (rows top-to-bottom, then columns left-to-right): a fixed
/// order, so the entities land in a deterministic sequence and the state hash is stable.
/// Spawns go straight into `world`, like `scene.load` — this is the pre-tick
/// world-construction path, not a mid-iteration mutation, so no command buffer is
/// involved. Errors: `error.OutOfMemory` from growing a component column (a fresh spawn
/// never yields a stale handle, so `error.InvalidEntity` cannot occur here).
pub fn materialize(tm: Tilemap, world: *World) World.Error!void {
    for (tm.rows, 0..) |line, row| {
        for (line, 0..) |glyph, col| {
            const tile = tm.tileFor(glyph) orelse continue;
            const bundle = tile.bundle orelse continue;
            try placeCell(world, bundle, tm.cellToWorld(col, row));
        }
    }
}

/// Spawn one entity at `pos` with `bundle`'s components attached, in the same field
/// order `scene.load`/the command buffer use. The cell's `pos` is authoritative for the
/// `Transform`; `bundle.transform` is intentionally not read.
fn placeCell(world: *World, bundle: components.Bundle, pos: Vec3) World.Error!void {
    const e = try world.spawn();
    try world.setTransform(e, .{ .pos = pos });
    if (bundle.velocity) |v| try world.setVelocity(e, v);
    if (bundle.health) |h| try world.setHealth(e, h);
    if (bundle.collider) |c| try world.setCollider(e, c);
    for (bundle.data) |nv| try world.setDataByName(e, nv.name, nv.value);
}

const testing = std.testing;
const data = @import("data");

test "tilemap: cellToWorld maps col→+X, row→+Y from origin (identity/edge/negative)" {
    const Case = struct { origin: Vec3, cell: f32, col: usize, row: usize, want: Vec3 };
    const cases = [_]Case{
        // identity: origin cell of an origin-anchored unit grid is the origin.
        .{ .origin = Vec3.zero, .cell = 1, .col = 0, .row = 0, .want = Vec3.zero },
        // edge/scale: col→+X, row→+Y, both scaled by cell_size.
        .{ .origin = Vec3.zero, .cell = 2, .col = 3, .row = 1, .want = .{ .x = 6, .y = 2, .z = 0 } },
        // negative origin carries through (grid centred left/below the world origin).
        .{ .origin = .{ .x = -5, .y = -5, .z = 0 }, .cell = 1, .col = 0, .row = 0, .want = .{ .x = -5, .y = -5, .z = 0 } },
        .{ .origin = .{ .x = -9, .y = 10, .z = 4 }, .cell = 1, .col = 2, .row = 3, .want = .{ .x = -7, .y = 13, .z = 4 } },
    };
    for (cases) |c| {
        const tm: Tilemap = .{ .cell_size = c.cell, .origin = c.origin };
        try testing.expect(tm.cellToWorld(c.col, c.row).approxEql(c.want, 1e-6));
    }
}

test "tilemap: tileFor resolves a mapped glyph, first-match wins, unmapped is null" {
    const tm: Tilemap = .{
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 1 } } } } },
            .{ .glyph = '#', .bundle = null }, // duplicate: never chosen
            .{ .glyph = '.', .bundle = null },
        },
    };
    try testing.expect(tm.tileFor('#').?.bundle != null); // first '#' entry wins
    try testing.expect(tm.tileFor('.').?.bundle == null);
    try testing.expect(tm.tileFor(' ') == null); // unmapped glyph
}

test "tilemap: materialize places a wall collider at each '#' cell and skips walkable cells" {
    // A 3x3 ring of walls around one open centre. '#' places a static collider; '.'
    // and unmapped ' ' are walkable (no entity).
    const tm: Tilemap = .{
        .cell_size = 1,
        .origin = Vec3.zero,
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
            .{ .glyph = '.', .bundle = null }, // declared walkable marker
        },
        .rows = &.{
            "###",
            "#.#",
            "###",
        },
    };

    var world = World.init(testing.allocator);
    defer world.deinit();
    try materialize(tm, &world);

    // 8 wall cells become entities; the open centre and nothing else does.
    try testing.expectEqual(@as(usize, 8), world.count());
    try testing.expectEqual(@as(usize, 8), world.colliders.count());
    try testing.expectEqual(@as(usize, 8), world.transforms.count());

    // Row-major order: entity 0 is the top-left wall at the origin cell; each carries
    // a static collider at its cell's world position.
    const first = world.entityAt(0);
    try testing.expect(world.getTransform(first).?.pos.approxEql(Vec3.zero, 1e-6));
    try testing.expect(world.getCollider(first).?.is_static);
    try testing.expectEqual(@as(f32, 0.5), world.getCollider(first).?.shape.circle.radius);

    // The centre cell (col 1, row 1 → world (1,1,0)) has no entity: no transform there.
    for (world.transforms.slice()) |t| {
        try testing.expect(!t.pos.approxEql(.{ .x = 1, .y = 1, .z = 0 }, 1e-6));
    }
}

test "tilemap: materialize is deterministic — same grid, bit-identical state hash" {
    const tm: Tilemap = .{
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .health = .{ .current = 1, .max = 1 } } },
            .{ .glyph = 'x', .bundle = .{ .health = .{ .current = 2, .max = 2 } } },
        },
        .rows = &.{ "#x#", "x#x" },
    };
    var a = World.init(testing.allocator);
    defer a.deinit();
    var b = World.init(testing.allocator);
    defer b.deinit();
    try materialize(tm, &a);
    try materialize(tm, &b);
    try testing.expectEqual(a.stateHash(), b.stateHash());
    try testing.expectEqual(@as(usize, 6), a.count());
}

test "tilemap: materialize attaches per-cell data components a script can later read" {
    const tm: Tilemap = .{
        .legend = &.{
            .{ .glyph = 'o', .bundle = .{ .data = &.{.{ .name = "value", .value = 50 }} } },
        },
        .rows = &.{"o"},
    };
    var world = World.init(testing.allocator);
    defer world.deinit();
    try materialize(tm, &world);
    const e = world.entityAt(0);
    try testing.expectEqual(@as(?f64, 50), world.getData(e, world.dataColumn("value").?));
}

test "tilemap: parse a legend+rows grid from ZON (char glyphs, rows of chars)" {
    const src =
        \\.{
        \\    .cell_size = 2,
        \\    .origin = .{ .x = -1, .y = -1, .z = 0 },
        \\    .legend = .{
        \\        .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
        \\        .{ .glyph = '.', .bundle = null },
        \\    },
        \\    .rows = .{
        \\        "###",
        \\        "#.#",
        \\        "###",
        \\    },
        \\}
    ;
    const tm = try data.parse(Tilemap, testing.allocator, src);
    defer data.free(testing.allocator, tm);

    try testing.expectEqual(@as(f32, 2), tm.cell_size);
    try testing.expectEqual(@as(usize, 3), tm.rows.len);
    try testing.expectEqualStrings("#.#", tm.rows[1]);
    try testing.expectEqual(@as(u8, '#'), tm.legend[0].glyph);
    try testing.expect(tm.legend[0].bundle.?.collider.?.is_static);
    try testing.expect(tm.legend[1].bundle == null);
}

test "tilemap: parse round-trips a collider-free grid's shape (parse of authored ZON == value)" {
    // The bespoke serializer can't emit tagged unions (physics.Shape), so a full
    // serialize→parse round-trip isn't expressible for collider-bearing tilemaps —
    // exactly why scene.zig/prototype.zig cover colliders with parse-only tests. This
    // asserts the parse side deeply for a union-free grid: parse(authored) equals the
    // hand-written value, tile-for-tile.
    const original: Tilemap = .{
        .cell_size = 1.5,
        .origin = .{ .x = -2, .y = 3, .z = 0 },
        .legend = &.{
            .{ .glyph = 'a', .bundle = .{ .health = .{ .current = 4, .max = 8 } } },
            .{ .glyph = 'b', .bundle = null },
        },
        .rows = &.{ "ab", "ba" },
    };
    const src =
        \\.{
        \\    .cell_size = 1.5,
        \\    .origin = .{ .x = -2, .y = 3, .z = 0 },
        \\    .legend = .{
        \\        .{ .glyph = 'a', .bundle = .{ .health = .{ .current = 4, .max = 8 } } },
        \\        .{ .glyph = 'b', .bundle = null },
        \\    },
        \\    .rows = .{ "ab", "ba" },
        \\}
    ;
    const parsed = try data.parse(Tilemap, testing.allocator, src);
    defer data.free(testing.allocator, parsed);
    try testing.expectEqualDeep(original, parsed);
}
