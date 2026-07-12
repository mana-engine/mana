# 0014. Camera/projection is a configurable view; rendering stops hardcoding isometric

- Status: accepted
- Date: 2026-07-12

## Context

`src/engine/render.zig` `project()` hardcodes an **isometric** world→screen
projection (via `View.tile: core.math.TileMetrics`) as the *only* way a world is
framed into an image. Every game the engine renders is therefore forced to look
isometric. That violates the vision (CLAUDE.md invariant #6: *genre lives in
content, not `src/`*): isometric is a legitimate first-class *rendering* feature, but
it is a **camera choice**, not a property every game must share.

Concrete need driving this now: the North-Star game, Snake, is a **top-down grid**.
Rendered through the iso-only projection it becomes a diamond — wrong. More broadly,
any non-iso game (top-down, side-on, straight orthographic) is currently impossible
to display correctly.

The leak is confined to the render layer. The simulation is already
projection-independent: movement/input work in neutral world space
(`inputMoveSystem` maps arrow keys to world x/y; no system reads the projection), and
`stateHash` never sees screen coordinates. So this decision changes only how the
world is *framed for display*, not gameplay.

Non-negotiable (user directive; memory `isometric-is-camera-not-movement`):
**movement and sim logic must never depend on the camera.** A projection is a
view-time transform only.

## Decision

1. **Projection becomes a configurable camera view.** `render.View` carries a
   `projection` describing how world coordinates map to the screen — a tagged union
   over supported kinds, initially:
   - `orthographic` — straight axis-aligned / top-down (what a grid game like Snake
     wants), parameterised by a world→viewport scale.
   - `isometric` — the current `TileMetrics`-based projection, moved behind this
     variant **unchanged** (no regression for existing iso content).
   Further kinds (side / 2.5D, perspective) are additive later behind the same union;
   adding one is not a breaking change.
2. **`project()` dispatches on the projection kind** to compute each entity's screen
   position and its depth-sort key. The iso depth key (`x + y + z`) moves into the
   `isometric` arm; `orthographic` uses a plain axis key. The rest of the pipeline
   (quad building, palette, painter's-algorithm sort) is projection-agnostic and
   stays as-is.
3. **The projection is content-/view-driven, never compiled in.** The runner/scene
   selects the view (and its projection), ultimately from package data. The engine
   has no default genre and no hardcoded camera.
4. **The sim is untouched.** No sim/movement/collision code reads the projection;
   `stateHash` is unaffected; the determinism golden does not change. This is a
   render-side-only change (cosmetic, excluded from the state hash per the
   physics/VFX invariant).

## Consequences

- Snake and any non-iso game can render correctly; isometric stops being mandatory
  while remaining a fully-supported view.
- Existing iso rendering is preserved as one variant — no visual regression; the iso
  arm reproduces the current math, so iso-content golden fixtures stay valid.
- `View` gains a `projection` variant; its callers (`runRender`, `--play`'s
  `runPlay`) choose a projection — default `orthographic` for new content, `isometric`
  where content asks.
- A future camera (pan/zoom/follow) slots on top of the same projection view without
  touching gameplay.
- **First-lane scope:** introduce the union with `orthographic` + `isometric` arms,
  move the current iso math behind `isometric`, add `orthographic`, make the runner
  pick per package/scene, table-driven tests for both projections (identity/edge/
  negative), and a determinism check confirming the sim is unaffected. Side/
  perspective projections and a movable camera are deferred to their own follow-ups.
