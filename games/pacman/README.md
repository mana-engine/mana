# pacman — the second North-Star content package (#62)

Grid Pac-Man, implemented entirely as content: `game.zon` + `prototypes.zon` +
`scenes/maze.zon` + `rules.lua`. **No `src/` code is part of this package** — where the
engine cannot yet express something it is filed as a gap issue, not patched here (per
issue #62 and CLAUDE.md invariant #6: genre lives in content, never in `src/`).

## Status: discovery scaffold (blocked on three fundamentals)

The package loads and validates end-to-end like Snake — the manifest, scene, and
prototypes parse, `script_api = 1` is accepted under `-Denable-lua`, `on_scene_enter`
spawns the maze/dots/pellets/player/ghosts, and the grid timer moves the pieces
deterministically. Reusing the loop Snake proved (bootstrap → input → timer → mutate:
`on_scene_enter` + `on_key` + `mana.every` + `set_position`) plus the newer surface
(`mana.get`/`set` data components, `mana.random_int`) is deliberate — Pac-Man is meant
to *harden the general fundamentals*, not add genre glue.

It is **not** a finished Pac-Man, because three engine fundamentals do not exist yet.
Each is a genre-neutral capability (mazes, chasing agents, and collision recur across
Pac-Man, Tetris, the platformer, and the RPG), marked `GAP` at its use site and filed
as its own issue:

- **Tile / maze level data.** The maze wants to be scene *data* both the engine and
  content read — walls the native collision system consumes and the renderer draws as
  tiles. No tile/level/tilemap data model exists (scenes are flat inline entity lists,
  ADR 0004 §6), so the layout lives as an ASCII grid inside `rules.lua` and every wall
  and dot is spawned as an individual entity. **The biggest data gap.**

- **Native pathfinding / steering.** Ghost chase/scatter is grid pathfinding + steering
  along the maze, which CLAUDE.md places in *native* engine code — Lua only *selects*
  the target tile (chase Pac vs. scatter to a corner vs. flee). There is no
  pathfinding/steering port, so ghosts here are a placeholder random-legal-turn wander
  (seeded via `mana.random_int` so it stays deterministic). **The largest gap overall.**

- **Content-declarable colliders / native collision.** Pac-vs-wall, pac-eats-dot, and
  pac-vs-ghost are all Lua coordinate math because a content package cannot attach a
  `Collider` to a spawned entity — the `Bundle`/`EntityDef` schema carries
  transform/velocity/health/data but no collider, so the native `collision` system and
  its `on_collision_begin` event are unreachable from ZON/Lua. A grid game re-deriving
  overlap in Lua duplicates a native system.

What is **not** a gap (expressible today, and exercised here): the chase/scatter/
**frightened mode timing** (a scripted window over per-entity data — `mana.after` +
`mana.set`), per-entity script state (the `score` and `frightened` data components,
ADR 0024), deterministic randomness (`mana.random_int`, ADR 0022), and the full input
→ timer → move loop.

A lesser, already-known gap also visible here: **per-entity appearance** — walls, dots,
pellets, Pac, and ghosts all render as identical quads (no sprite/colour/size per
entity), and entity quads are a fixed pixel size rather than world-relative. Tracked
against the renderer generally, not re-filed for Pac-Man.

## Running

```
mise run build            # or: zig build -Denable-lua
zig build -Denable-lua run -- games/pacman   # headless: spawns the maze, ticks, prints a state hash
```

As the gaps land, this package becomes the acceptance test: a playable arrow-key
Pac-Man that also ticks headlessly and deterministically from an input trace. Pac-Man
stays open across multiple waves (#62), so this scaffold references it, never closes it.
