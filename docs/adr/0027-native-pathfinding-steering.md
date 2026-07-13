# 0027. Native pathfinding + steering: Lua selects the target, the engine steers

- Status: accepted
- Date: 2026-07-13

## Context

CLAUDE.md's most load-bearing scripting invariant is the division of labour between
native code and Lua: **native (Zig) owns pathfinding + steering; Lua owns only
*selection* — which target — never the steering itself.** "The engine executes *how*;
Lua decides *what*." A per-entity-per-frame Lua callback is explicitly wrong.

The engine has no pathfinding or steering today. The Pac-Man discovery scaffold
(`games/pacman`, #62/#84) makes the gap concrete: its ghosts are a random
legal-direction *wander* written as a placeholder, not a chase toward a target tile.
A maze game needs an agent that, given a target cell (its prey's tile, a scatter
corner, a flee tile), moves one step at a time along a path through the level grid —
and that path/step computation must be native, deterministic, and off the script's
per-frame budget.

The seams this builds on already exist:

- **The grid** — ADR 0026's `Tilemap` (`src/engine/tilemap.zig`): a scene resource of
  glyph rows where wall glyphs materialize as static colliders and other cells are
  walkable/empty. The pathfinder paths over *this* grid's walkable cells; it invents no
  parallel map.
- **Movement** — the `movement` system (`src/engine/systems.zig`) integrates
  `Transform.pos += Velocity.v * dt`. Steering reuses it: set the agent's `Velocity`,
  let `movement` integrate. No parallel movement path.
- **Selection write path** — named scalar data components (ADR 0024): a script writes a
  per-entity `f64` with the existing `mana.set`. This is how Lua sets the target with
  **no new scripting API** (see §3).
- **Component-from-data** — the `Bundle`/`EntityDef` pattern (ADR 0024/0025): a new
  built-in component is declared in scene/prototype/tilemap ZON and threaded through
  spawn by adding one optional field.

## Decision

### 1. A `NavAgent` built-in component marks a steerable agent

`components.zig` gains:

```zig
pub const NavAgent = struct {
    speed: f32 = 1, // world units / second along the path
};
```

It carries only the movement *rate*; it is content-declarable (a new optional
`nav_agent` field on `Bundle`/`EntityDef`, threaded through `scene.load`,
`prototype.bundleAt`, `tilemap` materialization, and the command buffer's `attach`,
exactly as `collider` was in ADR 0025). Like `Velocity` and `Controller`, a `NavAgent`
is movement **intent**, not authoritative state: its effect lands in the hashed
`Transform`, so it is **excluded from `stateHash`** (an empty `nav_agents` column also
adds zero bytes — a scene with no agents hashes bit-identically to before).

The **target cell is not stored on `NavAgent`.** It lives in two named data components
(§3), so a script can select it. `NavAgent` is the marker + config; the target is
selection state.

### 2. A native `nav` system does the pathfinding + steering

A new system `nav.navSystem` (`src/engine/nav.zig`), registered **before**
`movementSystem`. Each tick, for every `NavAgent` (visited in NavAgent-insertion
order) whose entity has a `Transform` on the scene tilemap and both target components
set:

1. Map the agent's world position to its current cell (`Tilemap.worldToCell`).
2. Read the target cell from the two data components.
3. Run a **deterministic breadth-first search** over the tilemap's walkable cells from
   the current cell to the target, and take the **first step** of a shortest path.
4. Steer: set the agent's `Velocity` toward that next cell's world centre, magnitude
   `NavAgent.speed`. `movement` integrates it the same tick.

If the agent is already at its target, or the target is unreachable / off-grid, the
step is null and the agent is stopped (zero velocity) — deterministically stays put.

The sim reaches the grid through a new borrowed `Sim.tilemap: ?*const Tilemap`,
surfaced to systems as `Context.tilemap` (null for every sim that never sets it — the
system then no-ops, so existing sims are unaffected). The capability lane landed only
the field, the `Context` plumbing, and the system, all exercised through `Sim` in
tests. **Wiring the runner** (`src/runtime/main.zig`) to set `Sim.tilemap` from the
loaded scene and register `navSystem` — so nav runs for real via `mise run run` — has
since **landed** (#62): both the one-shot and interactive loops borrow the scene's
tilemap into the sim and register a fixed standard system set
(`nav → movement → collision → regen`), a no-op for a package without a tilemap/agents.
Migrating `games/pacman`'s ghosts onto it landed in the same content lane.

**BFS shape.** Grid, 4-connected, uniform cost, fixed neighbour order **up, down,
left, right**, keeping the first parent to reach each cell; the first step is
recovered by walking parents back from the target. BFS on a uniform grid yields a
shortest path and, with the fixed neighbour order + first-parent rule, a **single
deterministic** path. Scratch (visited / parent / frontier) is a **fixed stack buffer**
bounded by `max_cells` (64×64) — no heap in the hot loop; a grid larger than the bound
leaves the agent stationary (a maze is small — the bound is generous for Pac-Man's
~28×31). Walkability is derived from the tilemap: a cell is a **wall** iff its glyph
maps to a legend tile whose bundle attaches a `Collider`; everything else (unmapped,
bundle-less, collider-less, or out of grid range) is walkable.

### 3. Lua does zero steering — selection only, via the existing `mana.set`

The target cell is two named data components (ADR 0024) on the agent:
`nav_target_col` and `nav_target_row`. A script selects a target with the **existing**
API — `mana.set(agent, "nav_target_col", c)` / `mana.set(agent, "nav_target_row", r)`
— from an event handler or timer (e.g. `on_collision_begin`, a re-target `every`).
A scene/prototype declares the two `data` components on the agent (initial value = its
own cell ⇒ stationary until selected). **No `mana` API surface is added**, so this ADR
introduces no change to the ADR 0003 scripting contract. The per-tick pathfinding and
movement are entirely native; there is no per-entity-per-frame Lua callback.

### Determinism

`nav` visits agents in insertion order; BFS is fixed-order and first-parent; steering
is a fixed float sequence — so identical world state yields an identical velocity, and
the resulting `Transform` (hashed) is bit-identical run-to-run. `NavAgent` is out of
the hash; the target data components are in it (they are authoritative selection
state, folded in via ADR 0024's existing dense-order hashing). A scene with **no** nav
agents declares no `nav_agents` column and no nav data components, so the pinned
determinism golden (`tests/determinism.zig`, a nav-free scene) is **unaffected** and
does not move.

## Consequences

- **Easier:** a maze game gets real chase/scatter/flee for free — content selects a
  target cell in Lua; the engine finds the path and steers. The ghost placeholder wander
  can be replaced by selection logic that only picks *which* tile.
- **Harder / owned:** the BFS neighbour order and agent-visit order are part of the
  determinism contract and must not change without a reviewed golden update. The
  `max_cells` bound is a hard limit until a game needs a bigger grid.
- **Committed to:** the target is expressed as two `f64` data components by convention
  name (`nav_target_col`/`nav_target_row`); steering is velocity-into-`movement`, not a
  bespoke mover.
- **Follow-ups since landed:**
  - **Runner wiring of `Sim.tilemap`** — **DONE** (#62): `src/runtime/main.zig` now sets
    `Sim.tilemap` from the loaded scene and registers `navSystem`/`collisionSystem` in a
    fixed standard order, so nav runs for real via `mise run run`. Split out of the
    engine-capability lane so that one stayed free of runtime-orchestration churn.
  - **Migrating `games/pacman`'s ghosts** onto `NavAgent` — **DONE** (#62): the content
    package now selects target cells in Lua and lets the engine steer.
- **Explicitly not doing (follow-ups):**
  - **A\* / weighted costs / flow fields** — BFS on a uniform grid is deterministic and
    sufficient for Pac-Man; weighted terrain or a shared flow field is a later ADR.
  - **Non-grid nav graphs** — navmeshes, waypoint graphs, portals. Out of scope; the
    grid is the only topology.
  - **Flocking / local avoidance / separation** — agents do not avoid each other; two
    agents may share a cell. A steering-behaviours layer is a separate lane.
  - **A dedicated `mana` target-setter** (`mana.set_nav_target`) — deliberately avoided;
    reusing `mana.set` keeps the scripting surface unchanged. If a game ever needs it,
    that is its own ADR (a scripting-API change).
