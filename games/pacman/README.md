# pacman — the second North-Star content package (#62)

Grid Pac-Man, implemented entirely as content, in the modular by-kind layout (ADR
0038): `game.zon` + `prototypes/` (globbed & merged — `pac.zon` + `ghosts.zon`) +
`scenes/maze.zon` + `scripts/rules.lua`. **No `src/` code is part of this package** — the engine
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

- **Per-entity appearance — CLOSED (ADR 0030, #98).** Walls, dots, pellets, pac, and
  ghosts each declare an `.appearance` (color + world-space size) in `prototypes.zon`/
  `scenes/maze.zon`; the renderer sizes and colors every quad from that data instead of
  an identical fixed-size, palette-by-spawn-order square. Four ghost prototypes
  (`ghost_red`/`ghost_pink`/`ghost_cyan`/`ghost_orange`) give the ghosts distinct colors.

- **Four ghosts, four distinct chase behaviors — CLOSED (Refs #62).** The one real gap
  left in this package: three ghosts that all `set_target`ed pac's cell identically.
  `rules.lua`'s `retarget` now selects a different target per spawn index in chase mode
  — still selection-only (ADR 0027 §3), no engine surface added:
  - **Blinky** (red): pac's own cell — a direct chase (the original, unchanged behavior).
  - **Pinky** (pink): the cell `PINKY_AHEAD` (4) cells ahead of pac's heading — an ambush.
  - **Inky** (cyan): the cell two ahead of pac, mirrored through Blinky's *current* cell
    and doubled — Blinky's position bends Inky's approach.
  - **Clyde** (orange): chases like Blinky while farther than `CLYDE_CHASE_DIST_SQ`
    (8 cells) from pac; inside that radius he retreats to his own scatter corner instead.

  "Pac's facing direction" (needed for Pinky/Inky) uses **no new `mana` API** — `on_key`
  already tracks pac's heading in the local `pac_dir` variable (used for pac's own nav
  target); `retarget` reuses that existing selection state. Scatter and frightened
  targeting are unchanged (every ghost's own corner / flee-to-corner).

- **Runtime tint + blink cues — CLOSED (ADR 0033 phase 2, issue #128; subsumes the
  frightened-blue half of #106).** Pac and the four ghosts each declare a `.tint_cue`
  (`prototypes.zon`): a named list of override colors, some blinking. A script selects
  the active state by writing a **1-based index** to an EXISTING ADR 0024 data
  component — no new `mana` API. Ghosts reuse their existing `frightened` flag, widened
  from 0/1 to a 0/1/2 tri-state: 1 = solid frightened blue, 2 = blinking blue/white,
  which `begin_fright` flips to `BLINK_LEAD` (2s) before the window closes — the classic
  "frightened is about to end" warning. Pac gets a new `flash` data component that
  `on_collision_begin`'s fruit branch sets to 1 (a 12 Hz dim/bright strobe — pac's sprite
  tint MULTIPLIES its texel, so darkening is the reliable direction, not brightening past
  the texture's own color) then back to 0 a beat later (`mana.after`). The engine's
  `tint.advance` (cosmetic, wall-clock,
  hash-excluded — mirrors `sprite.advance`) resolves the displayed color every frame;
  `render.project`/`projectSprites` read it ahead of `Appearance.color`. A single fruit
  pickup (`scenes/maze.zon`, `kind` 5) exists solely to exercise the pac-flash cue.

- **Data-bound score/lives HUD — CLOSED (ADR 0034, issue #133).** `hud.zon` is a
  `ui.Screen` widget tree (the #132 widget/layout format) — a score label and a lives
  label, display-only — declared as CONTENT and wired in `game.zon` via `.hud`. Each
  label `bind`s a data component (ADR 0024): `score` (already tracked by `add_score`) and
  a new `lives` (declared on the `pac` prototype at 3, decremented by `reset_actors` on a
  fatal ghost catch — no new `mana` API). The engine fills the `ui.Host` seam from the
  live world (`render_ui.worldHost`) and composites the HUD over the game frame in both
  `--play` and the headless `--render-play-frame` (the font glyph atlas is merged into the
  scene sprite atlas so one bound texture carries sprites *and* glyphs). The HUD reads
  gameplay state one-way and writes nothing, so it is cosmetic and cannot perturb the
  state hash.

What was **never** a gap and is unchanged: chase/scatter/frightened mode *timing*
(`mana.after`/`mana.every` + `mana.set`), per-entity data (`score`, `frightened`, ADR
0024), and the input→heading path (`on_key`) Snake proved.

The runner wiring that made nav/collision reachable from a package —
`Sim.tilemap` plus registering the standard `nav → movement → collision → regen` system
set — landed alongside this migration (the follow-up ADR 0027 had deferred). It is
genre-neutral: registering nav/collision is a no-op for a package without a tilemap,
agents, or colliders (snake/sandbox are bit-identical).

## Still deferred (genre-neutral, tracked in the ADRs — not Pac-Man gaps)

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

## Acceptance staircase (ADR 0028, issue #94)

`scenarios/*.zon` is the analogous staircase to Snake's, per what the native
tilemap/nav/collision sim supports today: spawn → move → turn → eats a dot → a
non-frightened ghost catch resets pac (not a kill) → a frightened catch sends a ghost
home instead → the chase/scatter mode timer changes a ghost's target. Each file isolates
one mechanic, so a red result names exactly which one broke:

```
zig build -Denable-lua run -- games/pacman --scenario games/pacman/scenarios/04_eat.zon
```

or the whole suite via `zig build -Denable-lua test` (`tests/acceptance_scenarios.zig`
drives every file here through `engine.scenario`, the same generic referee Snake uses).
