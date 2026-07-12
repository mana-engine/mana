# 0011. Character controller: move-and-slide via the command buffer

- Status: accepted
- Date: 2026-07-12

## Context

ADR 0008 named a kinematic "move-and-slide against static geometry" character
controller as vocabulary, built on sweep/overlap, and deferred it until a game
needed movement-vs-walls resolution. That controller is now the concrete need
(issue #9): an entity should move each tick and slide along static colliders
instead of penetrating them, deterministically, with its position change routed
through the ADR 0007 §3 command buffer — not written to `Transform` directly, the
same discipline every other system in `src/engine` follows.

The complication: ADR 0008 §5 explicitly left **sweep unimplemented** ("raycast,
sweep, and the character controller are named vocabulary but unimplemented until a
game exercises them"). A textbook continuous "move-and-slide" resolves against a
*swept* shape cast along the desired displacement. Building sweep now, speculatively,
to serve only this controller would violate "don't implement more physics than a
game exercises" (CLAUDE.md) — no game in the corpus needs continuous collision
against fast-moving thin geometry yet.

## Decision

Resolve the controller discretely, from `overlap`/`contact` alone, deferring sweep:

1. **`physics.contact(a, b) -> ?Contact`** (`src/physics/resolve.zig`) is added
   alongside `overlap`: for two overlapping bodies it returns a unit `normal`
   (pointing from `b` toward `a`) and penetration `depth`, dispatching on
   circle/capsule exactly like `overlap.overlap`. Capsule-vs-capsule reuses the
   closest-segment-points computation `overlap.zig`'s narrow phase already runs
   (factored out as `overlap.closestSegSeg`, behavior-preserving).
2. **`engine.controller.controllerSystem`** drives every entity with `Transform` +
   a non-static `Collider` + a new `Controller` component (`{ velocity, skin }` —
   `velocity` is desired displacement rate in world XY, `skin` a small resting
   clearance). Each tick, per controller: attempt the full desired displacement,
   find the deepest-penetrating static collider at that tentative position (deepest
   wins ties by collider-insertion order — deterministic), depenetrate along its
   contact normal, then project the remaining displacement onto the surface
   tangent (drop the into-surface component, keep the rest) and repeat up to a
   small fixed iteration bound (4) to resolve a corner within one tick. This is the
   classic discrete collide-and-slide (Kasper Fauerby's algorithm, minus the swept
   time-of-impact step) — a well-known, correct stand-in for a full sweep when the
   controller doesn't move more than roughly its own size in one tick.
3. The resolved position is queued via `ctx.commands.setTransform` (never written to
   `world.transforms` directly), so it is subject to the same per-system
   transactional rollback (ADR 0007 §9-style) as every other system, and is visible
   to the rest of the tick only after the flush.
4. `Controller` is excluded from `World.stateHash`, matching `Velocity`: it is
   input intent, not authoritative state. Its effect lands in `Transform`, which is
   hashed, so the controller's output stays inside the determinism guarantee
   without widening the hashed surface.

## Consequences

- **Easier:** a game can drop a `Controller` + `Collider` onto an entity and get
  correct wall-sliding for free, with zero new orchestration (system registration is
  the only seam touched, per ADR 0007 §2); `physics.contact` is now available for any
  future consumer needing penetration depth/normal, not just the controller.
- **Harder / owned:** the discrete resolution can tunnel through thin static geometry
  if a controller's per-tick displacement exceeds roughly its own diameter — an
  explicit, documented bound (see `controllerSystem`'s doc comment), not a silent
  correctness gap. A corner is resolved within one tick only up to the 4-iteration
  budget; a corner formed by more than two overlapping walls at once is out of scope
  (no game exercises it).
- **Not doing (deferred, unblocked by this ADR):** continuous sweep/raycast queries
  (still ADR 0008 follow-ons); dynamic bodies, restitution, or friction beyond what
  sliding needs; a `.controller` scene-schema field (content wiring is a follow-on
  once a game needs it, mirroring `Collider`'s own deferred schema wiring).
