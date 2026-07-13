# pacman — the second North-Star content package (#62)

Grid Pac-Man, implemented entirely as content: `game.zon` + `prototypes.zon` +
`scenes/maze.zon` + `rules.lua`. **No `src/` code is part of this package** — the engine
is genre-neutral; where it once could not express something, that was filed as a
gap issue and fixed as a *general* engine capability, never patched here (issue #62 and
CLAUDE.md invariant #6: genre lives in content, never in `src/`).

## Status: runs headless and deterministically on the engine fundamentals

The three fundamentals the discovery scaffold was blocked on have landed as
genre-neutral engine features, and this package is now migrated onto them:

- **Tile / maze level data — CLOSED (ADR 0026, #81).** The maze is `scenes/maze.zon`'s
  `.tilemap`: a legend + rows the engine materializes on load. `'#'` maps to a static
  `Collider`, so wall cells become native level geometry the `nav` pathfinder treats as
  non-walkable. The ASCII grid and the per-cell `mana.spawn` loop are gone from Lua.

- **Native pathfinding / steering — CLOSED (ADR 0027, #82).** Ghosts *and* pac are
  `NavAgent`s. `rules.lua` only **selects** a target cell — it writes `nav_target_col`/
  `nav_target_row` with `mana.set` (chase = pac's cell, scatter = a corner, frightened =
  flee) — and the engine's `nav` system BFS-paths and steers every tick. There is no
  pathfinder and no per-entity-per-frame loop in Lua. The player is the same seam:
  input picks pac's heading, which the selection pass turns into a target cell.

- **Content-declarable colliders / native collision — CLOSED (ADR 0025, #83).** Dots,
  pellets, pac, and ghosts carry ZON-declared `Collider`s with a `kind` data tag; pac
  eating a dot/pellet and pac meeting a ghost are `on_collision_begin` events classified
  by that tag — not Lua coordinate math. Layers filter the pairs down to
  pac↔dot / pac↔pellet / pac↔ghost.

What was **never** a gap and is unchanged: chase/scatter/frightened mode *timing*
(`mana.after`/`mana.every` + `mana.set`), per-entity data (`score`, `frightened`, ADR
0024), and the input→heading path (`on_key`) Snake proved.

The runner wiring that made nav/collision reachable from a package —
`Sim.tilemap` plus registering the standard `nav → movement → collision → regen` system
set — landed alongside this migration (the follow-up ADR 0027 had deferred). It is
genre-neutral: registering nav/collision is a no-op for a package without a tilemap,
agents, or colliders (snake/sandbox are bit-identical).

## Still deferred (genre-neutral, tracked in the ADRs — not Pac-Man gaps)

- **Per-entity appearance.** Walls, dots, pellets, pac, and ghosts all render as
  identical fixed-size quads (no per-entity sprite/colour/size, no world-relative
  sizing). Tracked against the renderer generally (ADR 0014 lineage), not re-filed here.
- **Tile → prototype-name mapping (ADR 0026 follow-up).** A legend that names a
  `prototype` per cell (rather than an inline bundle) would let dots/pellets be tilemap
  cells too; it needs the prototype `Registry` threaded through the registry-free
  scene-load seam. Until then the collidable pickups are scene `entities`, not tilemap
  cells — a tilemap cell with a collider reads as a nav *wall*, so pickups must live
  outside the grid. Dots here are a curated subset, not every corridor cell.
- **A\* / weighted costs / flow fields, non-grid nav, local avoidance (ADR 0027
  follow-ups).** Nav is uniform-cost BFS on the grid; agents do not avoid each other.

## Running

```
zig build -Denable-lua run -- games/pacman   # headless: materialise the maze, spawn
                                             # pac/ghosts, tick 60 steps, print a hash
```

The headless run is the acceptance test: it spawns the maze/dots/pac/ghosts, ticks
deterministically (a stable state hash, bit-identical across two runs), and pac eats a
dot through native collision along the way. Real-time arrow-key `--play` needs SDL3 +
Vulkan (a manual step, out of scope for the headless gate). Pac-Man stays open across
multiple waves (#62), so this package references it, never closes it.
