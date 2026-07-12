# snake — the North-Star content package (#31)

Grid Snake, implemented entirely as content: `game.zon` + `prototypes.zon` +
`scenes/board.zon` + `rules.lua`. **No `src/` code is part of this package** — where
the engine cannot yet express something, it is filed as a gap issue, not patched here
(per the issue #31 constraint and CLAUDE.md invariant #6: genre lives in content).

## Status: blocked (a discovery artifact)

The package loads and validates end-to-end today — the manifest, scene, prototypes,
and `rules.lua` all parse, `script_api = 1` is accepted under `-Denable-lua`, and the
sim runs — but the snake never appears (**0 entities**): the scripting runtime has
the `mana` *accessor* surface (#5, #45) but not yet the *event/driver* model a game
needs. Attempting to build Snake surfaced these concrete gaps:

- **#54** — no start/bootstrap event, so the script can't initialize with a live host
  (spawn the snake, schedule the timer). `on_room_enter` here is the intended hook.
- **#55** — timers (`mana.every`/`after`/`cancel`) aren't wired to Lua, so there's no
  periodic move driver.
- **#56** — no `mana.set_position`, so segments can't teleport to grid cells.
- **#57** — no script input access, so the heading can't change on the arrow keys.
- **#47** — `mana.random_int` (seeded Sim RNG) for food placement.

Each gap is marked `GAP` at its use site in `rules.lua`. As they land, this package
becomes the acceptance test: `mana games/snake --play` should be a playable arrow-key
Snake, and it should also tick headlessly and deterministically from an input trace.
