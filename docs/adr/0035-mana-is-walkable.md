# 0035. `mana.is_walkable`: a read-only tilemap-walkability query

- Status: accepted
- Date: 2026-07-14

## Context

`games/pacman/rules.lua` carried a `WALLS` table — an ASCII picture of
`scenes/maze.zon`'s tilemap, hand-copied and kept in sync by comment discipline
alone (`WALLS` was "mirrored from scenes/maze.zon's tilemap `.rows`... MUST stay in
sync with maze.zon"). Its only reader was `is_wall`/`farthest_open`: pac's
straight-run target selection (#139) needs to know how far a corridor runs before a
wall. The #139 reviewer flagged this as a drift hazard — two copies of the same
walkability data, one in content ZON the engine actually reads (materialized by
`src/engine/tilemap.zig`'s `Tilemap`, ADR 0026, and paced over by the native `nav`
BFS, ADR 0027), one hand-maintained in Lua that nothing keeps honest if the maze
changes.

At the time `rules.lua`'s own comment cited ADR 0003 as the reason it couldn't do
better: "The ADR 0003 scripting API exposes no tilemap-walkability query... so the
picture lives here as package content — no new `mana` API." That framing was the
gap, not a constraint: ADR 0027 §3 fixed that *steering* stays native and *selection*
stays Lua, never that Lua selection must be blind to the grid it selects over. A
read-only walkability query is exactly the kind of narrow, load-bearing addition ADR
0003 §5 anticipates — "any change to the surface... requires its own ADR" — and
adding it removes the mirror entirely rather than papering over it.

The engine already has the single source of truth: `Sim.tilemap: ?*const Tilemap`
(ADR 0027) borrows the scene's grid, and `Tilemap.isWalkable(col, row) -> bool`
(`src/engine/tilemap.zig`) is the exact predicate — a cell is walkable unless its
glyph's legend bundle carries a `Collider`, and an out-of-grid cell reads `false`.
The gap was only that this predicate never reached the ADR 0015 host seam the other
live-Sim `mana` accessors (`position`, `get`, `random`, …) already cross.

## Decision

### The query: `mana.is_walkable(col, row) -> bool`

Added to the ADR 0003 §2 `mana` table, following its existing conventions:

- **Shape.** `mana.is_walkable(col, row)`: two integer grid coordinates in the
  scene tilemap's frame (the same `(col, row)` frame `nav_target_col`/
  `nav_target_row`, ADR 0027, already use), returning a plain Lua boolean.
- **Read-only, immediate.** Like `mana.position`/`mana.get`/`mana.random`, this is
  an immediate read through the host seam — never deferred, never queued on the
  command buffer, because it touches no entity state, only static level geometry.
- **No new handle, no new event.** It takes plain integers, not an opaque handle —
  there is no entity here, only a grid coordinate — so ADR 0003 §4's handle-safety
  rules are moot for this accessor.
- **Graceful degradation.** `false` when no Sim is dispatching (no host installed),
  the sim has no tilemap, the cell is off-grid, **or a coordinate is outside `i32`
  range** — the same "safe default, never raise" pattern `mana.get` (`nil`) and
  `mana.random` (`0`) already use. `false` is the correct safe default here
  specifically: "unknown" and "not walkable" collapse to the same answer a caller
  needs (don't path through an unqueryable cell). Never a raised error and, per ADR
  0003 §9, **never a panic**: Lua integers are `i64`, so the `i64→i32` narrowing uses
  `std.math.cast` (out-of-range ⇒ `false`), not a checked `@intCast` that would abort
  the engine on a content bug. An out-of-`i32` coordinate is off any real grid, so
  `false` is also the *correct* answer, not just a safe one.
- **Delegates, never re-derives.** The host-side implementation is a direct call to
  `Tilemap.isWalkable` — the exact function `nav`'s BFS already paths over
  (`src/engine/nav.zig`). No walkability logic is duplicated at the script seam;
  `mana.is_walkable` is a thin read of the one true grid.

### Wiring (ADR 0015 host seam, the established pattern)

- `src/script/host.zig`'s `Host.VTable` gains `is_walkable: *const fn (ctx, col:
  i32, row: i32) bool`, plus the `Host.isWalkable` forwarder — mirroring every
  other accessor already there.
- `src/script/mana.zig` gains `manaIsWalkable`, wired into `pushManaTable` as
  `mana.is_walkable`, calling the host when present and returning `false`
  otherwise — the same shape as `manaRandom`.
- `src/engine/script_runtime.zig`'s `DispatchCtx` and `LuaRuntime.HostCtx` gain a
  borrowed `tilemap: ?*const Tilemap` field (mirroring `Sim.tilemap`/
  `Context.tilemap`, ADR 0027), and `HostCtx.isWalkable` forwards straight to
  `tilemap.isWalkable(col, row)`, `false` if the sim has none.
- `src/engine/sim.zig`'s `Sim.tick` passes `.tilemap = self.tilemap` into the
  `DispatchCtx` literal it already builds every tick — one field, no new plumbing.

### Versioning (ADR 0003 §5)

`mana.version` **stays `1`.** ADR 0003 §5 is explicit that the v1 surface is
**additive within a version** — a new function is not a breaking change and does
not bump the integer; only a removal or a changed signature/payload would. This
matches every prior scripting-surface ADR since v1 shipped (0019 timers, 0020
`set_position`, 0021 `on_key`, 0022 `random`/`random_int`, 0024 `get`/`set`): each
added a member to the table under its own ADR without moving `mana.version`. This
ADR follows the same precedent — no version-gate change for content packages.

### `games/pacman/rules.lua`

`WALLS` and `is_wall` are **deleted**. `farthest_open` calls `mana.is_walkable`
directly:

```lua
local function farthest_open(col, row, dc, dr)
    local c, r = col, row
    while mana.is_walkable(c + dc, r + dr) do
        c, r = c + dc, r + dr
    end
    return c, r
end
```

`WALLS`' out-of-bounds convention (`col < 0 or col >= W or row < 0 or row >= H` →
wall) and `Tilemap.isWalkable`'s (negative or past the grid → `false`) agree
exactly, so this is a drop-in replacement with **no behavior change** — confirmed
by re-running every `scripts/games.sh scenarios pacman` scenario before and after:
output (including every assertion's tick number) is byte-identical. The mirror was
exact; there was no correction to make.

## Consequences

- **The drift hazard is gone.** There is exactly one walkability picture
  (`scenes/maze.zon`'s tilemap), read by both the native `nav` BFS and Lua's target
  selection through the same `Tilemap.isWalkable`. A future maze edit cannot leave
  Lua's copy stale, because there is no copy.
- **A small, precedented scripting-surface addition.** One read-only function,
  additive, no version bump, following the exact host-seam pattern every prior
  accessor used — no new category of risk to the sandbox or determinism story.
- **Determinism unaffected.** The query reads immutable-for-the-tick level data
  (the tilemap never changes mid-run) and returns a value, never mutating world
  state — no command-buffer entry, no state-hash interaction. The pinned
  determinism golden (`tests/determinism.zig`, the `sandbox` game, tilemap-free)
  does not move.
- **Committed to:** `(col, row)` integer grid coordinates in the scene tilemap's
  frame, matching `nav_target_col`/`nav_target_row`'s existing convention; `false`
  for wall/out-of-grid/no-tilemap, never an error.
- **Explicitly not doing:** exposing the tilemap's shape/size, cell-to-world
  conversion, or any other tilemap introspection — this ADR adds exactly the one
  predicate the drift hazard needed fixed. A future game that needs more tilemap
  surface from Lua is its own ADR.
