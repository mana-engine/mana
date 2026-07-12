# 0008. Physics port + first adapter: hand-rolled 2.5D collision

- Status: accepted
- Date: 2026-07-12

## Context

Physics is one of the architecture's named ports (CLAUDE.md "Physics & VFX"): a
subsystem edge with adapters chosen at comptime. Nothing physical exists yet — the
sim integrates velocity into position (ADR 0004 §5) and stops there. ADR 0007 §4
already forward-declared a `collision_begin` event and named "a collision /
character-controller system" as a seam that plugs into the frame pipeline without
editing orchestration. This ADR fixes the physics *vocabulary* and ships its first,
deliberately minimal adapter.

The invariant the port must respect: **deterministic within the sim, or cosmetic and
excluded from the state hash.** Collision decides gameplay (who overlaps whom), so it
is squarely on the deterministic, sim-side of that line — no floats hashed, no
globals, no wall-clock, no I/O. That is also why we do *not* reach for Box2D/Jolt
now: those bring dynamics (integration, restitution, solvers) no game in the corpus
exercises, and cross-platform bit-determinism from a third-party solver is a research
problem. Per "don't implement more physics than a game exercises," the first adapter
is hand-rolled.

## Decision

### 1. The port vocabulary (what `physics` owns)

- **Colliders**: `circle` and `capsule`. A `Shape` is the *local* collider a
  component stores; `place(shape, center)` positions it into a world-space `Body`.
  Collision is computed on the **world XY plane** — 2.5D: the entity `Transform`
  carries Z for layering/rendering, but Z does not enter the overlap test. A capsule
  is a segment + radius (a 2D stadium); a zero-length capsule degenerates to a
  circle. Circle + capsule are the two shapes a top-down/isometric character and its
  level geometry need; boxes/polygons are a follow-on if a game needs them.
- **Collision layers**: `Layers { layer, mask }` bitmasks. Two colliders interact
  only when each one's `mask` includes the other's `layer` (a **bidirectional**
  handshake). Bit meanings are a game's convention; the engine only filters.
- **Queries** (the port's surface, only the first is implemented now):
  - **overlap** — do two bodies share a point? (Implemented: circle/capsule pairs.)
  - **raycast** — first hit of a ray against colliders. (Vocabulary; follow-on.)
  - **sweep** — swept-shape cast for continuous collision. (Vocabulary; follow-on.)
- **Character controller**: a kinematic "move-and-slide against static geometry"
  helper built on sweep/overlap. (Vocabulary; follow-on — the first game to need
  movement-vs-walls resolution pulls it in, along with sweep.)

### 2. First adapter: hand-rolled 2.5D (`src/physics/`)

Imports `core` only (it sits beside the other ports in the DAG; `engine` imports
`physics`). Pure data + free functions, no allocation in the math:

- `shape.zig` — `Circle`/`Capsule`/`Body`, local `Shape` + `place`, `Aabb.ofBody`.
- `overlap.zig` — `overlap(a, b)` dispatching to circle-circle, circle-capsule, and
  capsule-capsule squared-distance tests (no square roots).
- `broadphase.zig` — `SpatialHash`: a uniform grid that buckets each body into every
  cell its AABB covers, then yields **sorted, de-duplicated** candidate index pairs.
  Because a body occupies every cell its AABB touches, two bodies whose AABBs overlap
  always share a cell, so the broad phase never misses a true overlap — cell size
  tunes performance only. Sorting makes the output independent of hash-bucket
  iteration order, which is what keeps it deterministic.
- `layer.zig` — `Layers` + `canCollide`.

### 3. Engine wiring (what `engine` composes)

- A `Collider` component: `{ shape: physics.Shape, layers, is_static }`. `is_static`
  marks immovable level geometry — **static geometry is just an entity with a static
  collider** (a `World` column), the minimal representation the sandbox needs. No new
  scene-schema field yet; tests and content attach colliders via the `World` API.
  Wiring a `.collider` field into the ZON scene format is a follow-on under ADR
  0004's schema lineage.
- A `collision` **system** matching the ADR 0007 `System` signature
  (`*const fn(*Context) Allocator.Error!void`). Each tick it places every
  transform-bearing collider, runs the broad phase, and for each candidate pair
  applies the static–static skip, the layer filter, and the narrow-phase overlap
  test, enqueuing a **`collision_begin`** event (`{ a: Entity, b: Entity }`, added to
  the ADR 0007 `Event` union) per overlapping pair. Scratch lives in a per-tick arena
  over `ctx.gpa` (the sanctioned per-frame-arena pattern), retained across ticks by
  nothing.

### 4. Determinism

Entities are visited in collider-insertion order; broad-phase pairs are sorted;
event emission order follows. Same world state ⇒ same events, bit-for-bit. The
collision system is read-only over the world (it emits events, never mutates
transforms), so the pinned determinism golden (a transform hash, ADR 0004 §8) is
**unchanged** — colliders are not added to the state hash by this ADR. A future
character controller that *moves* entities will record its motion through the command
buffer and fold into the existing hash.

### 5. v1 scope boundary (kept deliberately small)

- **Overlap only.** Raycast, sweep, and the character controller are named vocabulary
  but unimplemented until a game exercises them.
- **Level-triggered.** `collision_begin` fires for every overlapping pair *every
  tick* the overlap holds. True edge semantics (fire once on enter; add a
  `collision_end` on separation) need a persistent contact set carried across ticks;
  since ADR 0007 systems are stateless function pointers, that state has no home yet.
  Deferred until a game needs enter/stay/exit distinctions.
- **No collision response.** Detection emits events; it does not push bodies apart.
  Resolution arrives with the character controller.

## Consequences

- **Easier:** the sandbox gets deterministic overlap detection and a `collision_begin`
  event scripting can later surface as `on_collision_begin` (ADR 0003); physics is a
  real port with a real adapter, so a future Box2D/Jolt adapter has a vocabulary to
  slot behind (via a new ADR); `engine` composes it with zero orchestration edits
  (ADR 0007 seam).
- **Harder / owned:** we own the collision math and its numerical edge cases
  (degenerate segments, touching-counts-as-overlap); raycast/sweep/controller and
  edge-triggered contacts are deferred debt we take on deliberately, each unlocked by
  a concrete game need.
- **Follow-on ADRs / tasks (unblocked, not in this one):** raycast + sweep queries;
  a move-and-slide character controller (with collision response); edge-triggered
  contacts + `collision_end` (persistent contact set); box/polygon colliders; a
  `.collider` scene-schema field; swapping in Box2D/Jolt when dynamics are needed.
