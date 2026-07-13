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

/// A grid coordinate: 0-based column and row. Signed so a pathfinder can probe an
/// off-grid neighbour (e.g. col -1) before `isWalkable` rejects it, without underflow.
pub const Cell = struct { col: i32, row: i32 };

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

    /// The column count spanning the widest row — the grid's logical width. A
    /// pathfinder bounds its scratch by `colCount * rows.len`; a ragged short row simply
    /// has its missing trailing cells treated as walls (`isWalkable` returns false).
    pub fn colCount(self: Tilemap) usize {
        var m: usize = 0;
        for (self.rows) |line| m = @max(m, line.len);
        return m;
    }

    /// True if grid cell (`col`, `row`) is walkable — inside the grid and not a wall.
    /// A cell is a **wall** iff its glyph maps to a legend tile whose `bundle` attaches
    /// a `Collider` (the static level geometry a maze materializes, ADR 0026); every
    /// other cell — an unmapped glyph, a bundle-less tile, or a tile with no collider —
    /// is walkable. Out-of-range indices (negative, past the last row, or past a short
    /// row's end) are non-walkable, so the grid border bounds a pathfinder without a
    /// wall ring. This is the topology the `nav` pathfinder (ADR 0027) paths over —
    /// derived from the tilemap, never a parallel map.
    pub fn isWalkable(self: Tilemap, col: i32, row: i32) bool {
        if (col < 0 or row < 0) return false;
        const r: usize = @intCast(row);
        if (r >= self.rows.len) return false;
        const line = self.rows[r];
        const c: usize = @intCast(col);
        if (c >= line.len) return false;
        const tile = self.tileFor(line[c]) orelse return true; // unmapped ⇒ walkable
        const bundle = tile.bundle orelse return true; // no components ⇒ walkable
        return bundle.collider == null; // a collider ⇒ wall
    }

    /// The grid cell containing world point `pos`, or null if `pos` maps outside the
    /// grid. Inverse of `cellToWorld`: rounds to the nearest cell on each axis; Z is
    /// ignored (the grid is a plane, ADR 0014). Used to find a nav agent's current cell
    /// (ADR 0027). `cell_size` must be non-zero (a zero-sized grid returns null).
    pub fn worldToCell(self: Tilemap, pos: Vec3) ?Cell {
        if (self.cell_size == 0) return null;
        const cf = @round((pos.x - self.origin.x) / self.cell_size);
        const rf = @round((pos.y - self.origin.y) / self.cell_size);
        const col: i32 = @intFromFloat(cf);
        const row: i32 = @intFromFloat(rf);
        if (col < 0 or row < 0) return null;
        const r: usize = @intCast(row);
        if (r >= self.rows.len) return null;
        if (@as(usize, @intCast(col)) >= self.rows[r].len) return null;
        return .{ .col = col, .row = row };
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
    if (bundle.nav_agent) |na| try world.setNavAgent(e, na);
    if (bundle.appearance) |a| try world.setAppearance(e, a);
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

test "tilemap: isWalkable — walls (collider) block, everything else is walkable, bounds are walls" {
    // '#' materializes a static collider (a wall); '.' is a declared marker with no
    // collider (walkable); ' ' is unmapped (walkable). Rows are ragged: row 1 is short.
    const tm: Tilemap = .{
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
            .{ .glyph = '.', .bundle = null },
            .{ .glyph = 'o', .bundle = .{ .health = .{ .current = 1, .max = 1 } } }, // component but no collider
        },
        .rows = &.{ "#.o", "#", "###" },
    };
    const Case = struct { col: i32, row: i32, want: bool };
    const cases = [_]Case{
        .{ .col = 0, .row = 0, .want = false }, // '#' wall
        .{ .col = 1, .row = 0, .want = true }, // '.' walkable marker
        .{ .col = 2, .row = 0, .want = true }, // 'o' has a health component but no collider ⇒ walkable
        .{ .col = 1, .row = 1, .want = false }, // past the short row's end ⇒ wall
        .{ .col = -1, .row = 0, .want = false }, // negative ⇒ wall
        .{ .col = 0, .row = 3, .want = false }, // past the last row ⇒ wall
    };
    for (cases) |c| try testing.expectEqual(c.want, tm.isWalkable(c.col, c.row));
}

test "tilemap: worldToCell inverts cellToWorld and rejects off-grid points" {
    const tm: Tilemap = .{
        .cell_size = 2,
        .origin = .{ .x = -1, .y = -1, .z = 0 },
        .legend = &.{.{ .glyph = '.', .bundle = null }},
        .rows = &.{ "...", "..." }, // 3 cols x 2 rows
    };
    // Round-trip: every in-grid cell centre maps back to itself.
    for ([_]Cell{ .{ .col = 0, .row = 0 }, .{ .col = 2, .row = 1 }, .{ .col = 1, .row = 0 } }) |cell| {
        const w = tm.cellToWorld(@intCast(cell.col), @intCast(cell.row));
        const back = tm.worldToCell(w).?;
        try testing.expectEqual(cell.col, back.col);
        try testing.expectEqual(cell.row, back.row);
    }
    // A point near a cell centre rounds to that cell.
    try testing.expectEqual(@as(i32, 1), tm.worldToCell(.{ .x = 0.9, .y = -1.1, .z = 0 }).?.col);
    // Off-grid points (below origin, past the last row) return null.
    try testing.expect(tm.worldToCell(.{ .x = -3, .y = -1, .z = 0 }) == null);
    try testing.expect(tm.worldToCell(.{ .x = -1, .y = 5, .z = 0 }) == null);
}

test "tilemap: colCount is the widest row's length" {
    const tm: Tilemap = .{ .rows = &.{ "##", "#####", "###" } };
    try testing.expectEqual(@as(usize, 5), tm.colCount());
    try testing.expectEqual(@as(usize, 0), (Tilemap{}).colCount()); // no rows ⇒ zero width
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

test "tilemap: materialize attaches a legend cell's appearance to its entity" {
    const tm: Tilemap = .{
        .legend = &.{
            .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true }, .appearance = .{ .color = .{ 0.2, 0.3, 0.9 }, .size = 1 } } },
        },
        .rows = &.{"#"},
    };
    var world = World.init(testing.allocator);
    defer world.deinit();
    try materialize(tm, &world);
    const e = world.entityAt(0);
    const a = world.getAppearance(e).?;
    try testing.expect(std.mem.eql(f32, &.{ 0.2, 0.3, 0.9 }, &a.color));
    try testing.expectEqual(@as(f32, 1), a.size);
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
