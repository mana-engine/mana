# 0026. Tilemap level data: a grid-of-cells scene resource the engine materializes

- Status: proposed
- Date: 2026-07-13

## Context

Scenes today (ADR 0004 §6) are a flat inline list of `EntityDef` records — one
component set per entity, spawned individually by `scene.load`. There is no grid,
tilemap, or "level" concept. A grid game must therefore author its level *somewhere
else*: the Pac-Man discovery scaffold (`games/pacman/rules.lua`, #84) hard-codes its
maze as an ASCII grid **inside Lua** and, in `on_scene_enter`, spawns one entity per
cell with `mana.spawn`. That scaffold marks the problem explicitly (`GAP (tile/maze
level data)`): the layout is invisible to native collision, is not diffable/editable
as data, and costs O(cells) script spawns on load. Level geometry belongs in
human-editable data the engine interprets (invariant #1: files are the source of
truth; "prefer data over Lua"), not in a script.

ADR 0025 just closed the adjacent gap — a `.collider` can now be declared in the
scene/prototype schema, so a ZON-authored entity participates natively in the ADR 0008
`collision` system. That is exactly the primitive a tile grid needs: a wall cell is an
entity with a static `Collider`. What is still missing is the *compact grid authoring*
in front of it — writing 200 wall entities by hand is not "human-authorable."

This ADR adds a generic tile/grid level resource. It is a **data-authoring +
materialization seam**, not a new physics or rendering decision: walls reuse ADR 0025's
collider-from-data path verbatim, and the grid→world placement reuses the neutral world
coordinates the sim already works in (ADR 0014: the projection is a *view-time* choice;
a cell's world position is projection-independent — memory `isometric-is-camera-not-
movement`).

Scope is deliberately narrow: the **data model + materialization of the grid into
entities/colliders**. Drawing tiles as sprites (tile *rendering*) is a separate
follow-up (see "Explicitly not doing").

## Decision

### 1. A scene may carry an optional `tilemap`

`Scene` (`src/engine/scene.zig`) gains one optional field, `tilemap: ?Tilemap = null`,
beside its existing `entities`. An absent tilemap ⇒ the scene behaves exactly as before
(byte-for-byte, hash-for-hash — see Determinism), so every shipped scene is unaffected.

A `Tilemap` (new `src/engine/tilemap.zig`) is:

```zig
pub const Tilemap = struct {
    cell_size: f32 = 1,          // world units per cell
    origin: core.Vec3 = .zero,   // world position of cell (col 0, row 0)
    legend: []const Tile,        // glyph → what a cell of that glyph materializes
    rows: []const []const u8,    // the grid, one string per row, top-to-bottom
};

pub const Tile = struct {
    glyph: u8,                        // the cell character this entry maps
    bundle: ?components.Bundle = null, // components placed at each matching cell
};
```

The grid is authored as **a legend plus rows of characters** — the compact,
human-diffable form a maze wants:

```zon
.tilemap = .{
    .cell_size = 1,
    .origin = .{ .x = -9, .y = -5, .z = 0 },
    .legend = .{
        .{ .glyph = '#', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.5 } }, .is_static = true } } },
        .{ .glyph = '.', .bundle = .{ .collider = .{ .shape = .{ .circle = .{ .radius = 0.2 } }, .layers = .{ .layer = 2, .mask = 1 } } } },
    },
    .rows = .{
        "#####",
        "#...#",
        "#####",
    },
}
```

A glyph absent from the legend (e.g. `' '`), or a legend entry whose `bundle` is null,
is **walkable/empty**: nothing is spawned. This is what keeps a grid from spawning an
entity per floor cell — only meaningful cells become entities.

### 2. The engine interprets the grid generically

`scene.load` materializes the tilemap after its explicit entities, calling
`tilemap.materialize(tm, world)`. For each cell, in a **fixed row-major order**
(rows top-to-bottom, columns left-to-right):

- Look up `rows[row][col]` in the legend. Unmapped, or a null `bundle` ⇒ skip (walkable).
- Otherwise spawn one entity at the cell's world position, applying the tile's
  `bundle`: the cell supplies the `Transform` (`cellToWorld` below; any transform in the
  bundle is ignored, mirroring `prototype.bundleAt`), and each present bundle field —
  `velocity`, `health`, `collider` (ADR 0025), `data` (ADR 0024) — is attached exactly
  as `scene.load` attaches a normal entity's. A wall glyph is therefore an entity with a
  **static `Collider`** that participates in `collisionSystem` and can reach
  `on_collision_begin` — no new collision code, ADR 0025's path reused whole.

Spawns go straight into the `World` (like `scene.load`), which is the pre-tick
world-construction path, not a mid-iteration mutation — so no command buffer is
involved, and the fixed iteration order makes the entity sequence deterministic.

Grid→world placement:

```zig
pub fn cellToWorld(self: Tilemap, col: usize, row: usize) core.Vec3 {
    // col → +X, row → +Y, scaled by cell_size from origin; z = origin.z.
}
```

Column maps to +X, row maps to +Y. This is a straight, projection-independent world
layout; how it *looks* (top-down vs isometric) is the camera's job (ADR 0014).
Centering a grid on the origin is content's choice, expressed via `origin` — the engine
imposes no genre-specific convention (e.g. no y-flip).

### 3. Genre stays in content

The engine knows only: glyph → component bundle → world cell. What a glyph *means* (a
wall, a dot, a spawn point) lives entirely in the scene's legend and the game's
components — never in `src/` (invariant #6). `tilemap.zig` contains no maze/ghost/pac
concept; it is a generic grid interpreter.

### Determinism

Materialization order is fixed (row-major), so a given tilemap always produces the same
entity sequence and the same state hash. Colliders are read-only sim state and stay out
of `stateHash` (ADR 0008/0025), so wall cells add nothing to the hash; a tile carrying a
`health`/`data` component contributes through the existing hashed columns, in a fixed
order. Crucially, an **absent** tilemap changes nothing: `scene.load` runs its entity
loop and then materializes zero cells, so the pinned determinism golden
(`tests/determinism.zig`, a tilemap-free scene) is **unaffected** and does not move.

## Consequences

- **Easier:** a grid game authors its level as compact, diffable ZON data the engine
  reads — walls become native colliders, pickups become entities — instead of an ASCII
  grid inside a script spawning O(cells) entities. This is the data home the Pac-Man
  scaffold's `GAP (tile/maze level data)` asked for.
- **Harder / owned:** one new invariant — the row-major materialization order is part of
  the determinism contract and must not change without a reviewed golden update.
- **Committed to:** the tilemap's ZON shape is `cell_size` + `origin` + a glyph `legend`
  + `rows` of chars; a tile's payload is the canonical `components.Bundle`, so any future
  built-in component becomes placeable on a grid for free (same reason ADR 0024/0025
  needed no bespoke plumbing).
- **Explicitly not doing (follow-ups):**
  - **Tile rendering** — drawing tiles as sprites/quads. Materialization produces
    *entities* (with transforms) that the existing `render.project` already draws as
    quads; a dedicated tile/sprite renderer (sharing this same ZON) is a separate lane.
  - **Tile → prototype-name mapping** — a legend entry that names a `prototype` (ADR
    0016) to instance per cell, rather than an inline bundle. Useful (it would let a cell
    spawn a full named prefab, e.g. Pac-Man's dots/pellets/ghost-starts), but it requires
    threading the prototype `Registry` through the scene-load seam (which `scene.load` is
    intentionally registry-free today). Deferred to its own ADR/lane.
  - **Migrating `games/pacman`** onto the tilemap (moving its ASCII maze out of
    `rules.lua`) is a content change, out of this engine-capability lane.
  - No multi-layer grids, no non-rectangular topology, no chunking — added only when a
    real game needs them (no speculative flexibility).
