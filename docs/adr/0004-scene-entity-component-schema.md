# 0004. Scene/entity component schema + ECS storage model

- Status: accepted
- Date: 2026-07-12

## Context

The current `Sim` is a placeholder (a flat position array with RNG-seeded
velocities). It is the one load-bearing part of the stack that is a toy, and three
things now block on a real model:

- **ADR 0001** committed to a minimal custom ECS (dense IDs, contiguous SoA
  components, free-function systems) but it is still a stub.
- **ADR 0003** (scripting) requires **generational entity handles** (packed u32
  index + u32 generation) and a **component get/set** surface, plus a `game.zon`
  `.script_api` field — none of which exist yet.
- Rendering and physics (later) both need to read a real spatial component.

This ADR fixes the entity/handle model, the component storage model, the ZON scene
format, and the manifest's `script_api` field. It deliberately does **not** add
rendering, physics, or scripting — only the data spine they share. Per the
anti-speculation rule, it ships the smallest model that serves the sandbox today.

## Decision

### 1. Entities are generational handles

```zig
pub const Entity = struct { index: u32, generation: u32 };
```

- A `World` allocates entities from a free list; despawn bumps the slot's
  generation so any stale handle is detectable.
- `Entity` packs losslessly to/from a `u64` (`index` low, `generation` high) — this
  is the exact ABI the scripting layer hands to Lua (ADR 0003 §4). Packing lives in
  one place and changes only with a scripting-API version bump.
- `world.isValid(e)` compares the handle generation to the live slot; every accessor
  rejects a stale handle rather than touching a recycled row.

### 2. Component storage: sparse set per component

Each component type is stored as a **sparse set**: a packed **dense array** (what
systems iterate, cache-friendly) plus a sparse `entity index → dense slot` map.
This is the idiomatic minimal-custom ECS (ADR 0001) — it gives O(1) add/remove/has,
optional components per entity (an entity has a component only if present in that
set), and dense iteration, **without** archetypes. Iterating an intersection (e.g.
Transform ∧ Velocity) walks the smaller set and probes the other.

### 3. v1 built-in components (genre-neutral only)

The engine compiles in only spatial components its native systems operate on:

```zig
pub const Transform = struct { pos: Vec3 };          // room to grow: rot, scale
pub const Velocity  = struct { v: Vec3 };
```

A position is not genre-specific, so this does not leak genre into `src/`.
**Content-defined / script data components** (arbitrary named values a game or Lua
script attaches) are **deferred** to when scripting or a real game needs them —
adding a generic dynamic store now would be speculative. When added, they get their
own ADR and slot in beside the built-ins.

### 4. Component registry is comptime

A single comptime list of built-in component types drives the `World`: it generates
one sparse-set column per registered type. Adding a built-in component = add its
struct to the registry (and the systems that use it). No runtime type registration
(that is the archetype path ADR 0001 rejected).

### 5. Systems are free functions over the `World`

e.g. `movement(world: *World, dt: f32)` iterates entities with Transform ∧ Velocity
and integrates `pos += v·dt`. No behavior objects, no virtual dispatch. This
replaces the hardcoded loop in today's `Sim`.

### 6. Scene ZON schema

An entity is a record with a `name` and one optional field **per built-in
component** (omitted field ⇒ entity lacks that component). This parses with the
existing `data.zon` parser (optional fields default to null):

```zon
.{
    .name = "hello",
    .entities = .{
        .{ .name = "player", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } }, .velocity = .{ .v = .{ .x = 1, .y = 0, .z = 0 } } },
        .{ .name = "crate",  .transform = .{ .pos = .{ .x = 2, .y = 1, .z = 0 } } },
    },
}
```

The scene loader spawns an entity per record and adds each present component to the
`World`. Entity `name` is retained (debug/lookup); the component set is data.

### 7. `game.zon` gains `.script_api`

```zon
.script_api = 0,   // optional; 0/omitted = this package uses no scripting
```

The runner refuses to load a package whose `.script_api` exceeds what the build
provides (currently **0** — no scripting compiled in), with a clear message. This
implements the accepted ADR 0003 version gate honestly, before scripting exists.

### 8. Determinism is preserved

Entity index allocation (free-list order) and per-component dense iteration
(insertion order) are deterministic. The state hash now covers real component
columns. Because the scene format and sim semantics change (velocity is now scene
data, not RNG-seeded), the pinned determinism hash and the scene fixtures **change
as a reviewed golden update** in the implementing commit — the *guarantee* (same
seed + inputs ⇒ identical hash) is unchanged.

## Consequences

- **Easier:** generational handles unblock scripting; a real component model unblocks
  the scene schema, rendering's transform read, and future physics colliders; the
  determinism test now exercises meaningful state; adding a built-in component is a
  one-line registry change.
- **Harder:** systems that need a component *intersection* must walk sparse sets
  deliberately (no free archetype grouping) — acceptable at current scale, revisited
  by ADR only if a real game's iteration cost demands it.
- **Committed to:** migrating `engine.Sim` → `engine.ecs.World` + a `movement`
  system, updating `scene`, `runtime/main`, the sandbox scenes, and the determinism
  golden in one reviewed slice. `core.Rng` stays in core for gameplay use but is no
  longer wired into movement.
- **Follow-on ADRs (unblocked, not in this one):** content-defined data components;
  mid-tick add/remove via the command buffer (ties to ADR 0003 deferred mutations);
  Transform rotation/scale; a spatial index for physics broad-phase.
