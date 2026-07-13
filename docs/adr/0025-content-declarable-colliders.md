# 0025. Content-declarable colliders: `.collider` in the scene/prototype schema

- Status: accepted
- Date: 2026-07-13

## Context

ADR 0008 shipped the physics port and the `collision` system: a native `World`
column of `Collider { shape, layers, is_static }`, a per-tick broad+narrow phase over
transform-bearing colliders, and a `collision_begin` event that `script_runtime`
already dispatches to a script's `on_collision_begin` handler. But ADR 0008 §3 named
its own gap explicitly: *"No new scene-schema field yet; tests and content attach
colliders via the `World` API. Wiring a `.collider` field into the ZON scene format is
a follow-on under ADR 0004's schema lineage."*

That gap means content cannot use collision at all. `components.Bundle` (what the
command-buffer `spawn`/`attach` path applies), `scene.EntityDef` (what a ZON scene
declares), and `prototype.Prototype` (= `scene.EntityDef`, what `mana.spawn`
instantiates) carry `transform`/`velocity`/`health`/`data` but no `collider`. A
scene-authored or `mana.spawn`-ed entity — i.e. every entity a real game package
creates — never gets a `Collider`, never participates in `collisionSystem`, and
`on_collision_begin` never fires for content. Only a Zig test calling
`world.setCollider` directly exercises the feature ADR 0008 built. This is issue #83.

This is a pure data-authoring seam, not a physics decision — the collision algorithm,
`Shape`/`Layers` vocabulary, and event are exactly as ADR 0008 left them. The precedent
is ADR 0024, which threaded a new named **`data` component** through the identical
three call sites (`Bundle`, `EntityDef`, `Prototype`) and the same command-buffer
`attach` flush. This ADR repeats that shape for `collider` instead of inventing a new
mechanism.

## Decision

Add one optional field, `collider: ?components.Collider = null`, to the three places
ADR 0024 added `data` to, mirrored exactly:

- **`components.Bundle`** (`src/engine/components.zig`) — the set a deferred spawn
  attaches at flush.
- **`scene.EntityDef`** (`src/engine/scene.zig`) — what a scene ZON file declares per
  entity; `scene.load` calls `world.setCollider(e, c)` when present, alongside its
  existing `transform`/`velocity`/`health`/`data` handling.
- **`prototype.Prototype`** (`= scene.EntityDef`, reused wholesale per ADR 0016) —
  `bundleAt` carries `proto.collider` through to the bundle unchanged, the same way it
  already carries `data`.

The command buffer's `attach` flush (`src/engine/command.zig`) gains one line:
`if (a.bundle.collider) |c| try ignoreInvalid(world.setCollider(a.entity, c));` —
applied after `health`, before `data`, matching the field order in `Bundle`.

No new type is introduced. `Collider`'s shape — `shape: physics.Shape` (circle/
capsule union), `layers: physics.Layers` (`layer`/`mask` bitmasks, defaulting to "on
layer 1, collides with everything"), `is_static: bool` — is exposed to ZON exactly as
`World.setCollider` already accepts it. `std.zon.parse` (the parser `data.parse`
already builds on, ADR 0004) handles tagged unions and defaulted struct fields
natively, so `Shape`'s circle/capsule variants and `Layers`' defaults round-trip with
zero custom (de)serialization code — the same reason ADR 0024's `NamedValue` needed
none.

A scene author now writes, e.g.:

```zon
.{ .name = "wall", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } },
   .collider = .{ .shape = .{ .circle = .{ .radius = 1.5 } }, .is_static = true } }
```

and that entity is placed by `collisionSystem` every tick like any Zig-attached
collider, including reaching a script's `on_collision_begin`.

### Determinism

Unchanged from ADR 0008: `Collider` does not enter `World.stateHash` (it is read-only
sim state — the `collision` system only emits events, never mutates transforms). A
content-declared collider is applied through the same `world.setCollider` call a Zig
test already uses, so no new hash contribution and the pinned determinism golden is
unaffected by this ADR.

## Consequences

- **Easier:** a game package can declare collision geometry (level walls, pickups,
  hazards, character bodies) entirely in ZON — scenes and prototypes — and wire
  `on_collision_begin` handlers in Lua with zero native code. This closes the last gap
  between ADR 0008's engine-side collision system and content actually being able to
  use it.
- **Harder / owned:** none — this is additive data plumbing over an unchanged
  algorithm; no new invariant to maintain beyond the three call sites already
  established by ADR 0024's precedent.
- **Committed to:** `Collider`'s ZON shape is exactly its Zig shape (`shape`/`layers`/
  `is_static`); no schema translation layer. Future `Collider` fields (if physics ever
  grows one) become new ZON fields for free through the same `std.zon.parse` path.
- **Explicitly not doing:** no change to the collision algorithm, shapes, layers,
  event semantics, or the `on_collision_begin` dispatch (all ADR 0008, untouched); no
  box/polygon shapes; no per-frame Lua; no genre-specific collider content (that lives
  in `games/**`, never `src/**`).
