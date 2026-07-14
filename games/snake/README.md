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
grow → death — each file isolating one mechanic so a red result names exactly which
one broke. Run one with the headless CLI:

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
