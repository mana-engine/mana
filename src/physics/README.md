# src/physics

**Responsibility:** The physics port's first adapter — a hand-rolled, deterministic
2.5D collision kernel (see `docs/adr/0008`). Owns the collision vocabulary: circle
and capsule colliders (`Shape`/`Body`), collision-layer filtering (`Layers`), a
uniform spatial-hash broad phase (`SpatialHash`), narrow-phase overlap tests
(`overlap`), and contact resolution (`contact` — separating normal + penetration
depth for an overlapping pair, ADR 0011). Collision is computed on the world XY
plane; Z is carried by the transform but does not enter the tests (2.5D). Everything
is pure data + free functions — no I/O, no globals, no allocation in the math — so
it is sim-side and trivially deterministic (the physics/VFX invariant).

The `Collider` component, the registerable `collision` system, `collision_begin`
events, and the kinematic character controller (`controllerSystem`, built on
`contact`) live one level up in `engine` (this module has no ECS knowledge). Box2D/
Jolt may slot behind this same vocabulary later, via a new ADR, when a game needs
real dynamics — raycast and sweep queries are still-named follow-ons (ADR 0011: the
controller resolves discretely from `contact` rather than pulling sweep in early).

**May import:** `core` (and `std`). Nothing above.

**Imported by:** `engine`.
