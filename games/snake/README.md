# snake — the North-Star content package (#31)

Grid Snake, implemented entirely as content: `game.zon` + `prototypes.zon` +
`scenes/board.zon` + `rules.lua`. **No `src/` code is part of this package** — where
the engine cannot yet express something, it is filed as a gap issue, not patched here
(per the issue #31 constraint and CLAUDE.md invariant #6: genre lives in content).

## Status: runs headlessly and deterministically

The event/driver gaps this package originally surfaced — bootstrap (`on_scene_enter`,
closing #54), timers (`mana.every`/`after`/`cancel`, #55), `mana.set_position` (#56),
and script input access (`on_key`, #57) — have all landed as genre-neutral engine
features `rules.lua` now uses directly; #47 (`mana.random_int`) is still open, so food
placement uses a content-side deterministic PRNG until the seeded Sim RNG lands. The
snake spawns, advances one cell per grid tick, turns on input, eats and grows, and
resets on self/wall collision — see the acceptance staircase below, which is now the
executable proof (superseding the "0 entities" discovery-era status this section used
to report). Real-time arrow-key `--play` needs SDL3 + Vulkan (a manual step, out of
scope for the headless gate).

## Acceptance staircase (ADR 0028, issue #94)

`scenarios/*.zon` is the executable acceptance definition the paragraph above
gestures at: an ordered, single-mechanic staircase — spawn → advance → turn → eat →
grow → death → down → reverse rejected → turn after reject — each file isolating one
mechanic so a red result names exactly which one broke. The last three (issues #175,
#176) close a gap the first six left open: every earlier turn scenario pressed only
"up"/"down" as a single input, so nothing pinned the opposite key (`07_down.zon`,
mirroring pacman's #164/#168 down-key scenario) or the illegal-180°-reversal guard
(`08_reverse_rejected.zon`, `09_turn_after_reject.zon`). Run one with the headless CLI:

```
zig build -Denable-lua run -- games/snake --scenario games/snake/scenarios/04_eat.zon
```

or the whole suite via `zig build -Denable-lua test` (`tests/acceptance_scenarios.zig`
drives every file in this directory against `engine.scenario`, the generic referee).

## Sprites (issue #107)

`sprites/head.zon`, `sprites/segment.zon`, `sprites/food.zon` are `tools/spritegen`
recipes (ADR 0031) — the same genre-neutral generator and sprite/animation component
`games/pacman` uses, proving they are not Pac-Man-specific. `head.zon` is DIRECTIONAL
(ADR 0033: right/up/down authored, left mirrored) so the head faces its travel
direction; `segment.zon`/`food.zon` are non-directional idle animations. `mise run
assets` regenerates all three into `sprites/generated/` (gitignored); `prototypes.zon`
wires them onto the `head`/`segment`/`food` prototypes `rules.lua` spawns. Because
Snake teleports via `mana.set_position` rather than moving by velocity integration,
`rules.lua`'s `face` helper gives the head a magnitude-negligible `Velocity` purely to
drive the engine's directional-facing latch — see its doc comment for why the
magnitude cannot perturb the grid-snapped position (or the acceptance staircase
above, which pins the exact grid cells).

## Data-bound score/length HUD (ADR 0034, issue #177)

`hud.zon` is a `ui.Screen` widget tree (the #132 widget/layout format) — a score label
and a length label, display-only — declared as CONTENT and wired in `game.zon` via
`.hud`, mirroring `games/pacman`'s HUD (#133) exactly. Each label `bind`s a data
component (ADR 0024) declared on the `head` prototype: `score` (incremented 10 per
food eaten, mirrored by `rules.lua`'s `sync_hud`) and `length` (`#body`, the snake's
live segment count — no separate counter). Because `rules.lua` respawns a fresh `head`
handle on every `reset()`, `sync_hud` is only ever called later, from `step`'s eat
branch — never right after a spawn, before the engine has flushed the spawn command
and registered the columns; a fresh head's HUD values fall back to the `head`
prototype's own defaults (`score = 0`, `length = 1`) instead. The engine fills the
`ui.Host` seam from the live world (`render_ui.worldHost`) and composites the HUD over
the game frame in both `--play` and the headless `--render-play-frame`. The HUD reads
gameplay state one-way and writes nothing, so it is cosmetic and cannot perturb the
state hash.
