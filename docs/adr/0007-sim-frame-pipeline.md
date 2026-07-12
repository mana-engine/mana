# 0007. Simulation frame pipeline: systems, command buffer, event dispatch

- Status: accepted
- Date: 2026-07-12

## Context

Everything currently converges in `runtime/main.zig`, which hand-wires load → tick →
render for each mode. There is no engine-level integration seam, so scripting,
physics, and render-integration would all have to edit the same orchestration —
they cannot proceed in parallel. Two accepted ADRs already assume machinery that
does not exist: ADR 0003 (scripting) needs a **command buffer** (deferred/
transactional mutations), **event dispatch** (`on_spawn`/`on_hit`/…), and a timer
wheel; ADR 0005 deferred "the exact tick phase where the command buffer is flushed."

This ADR defines the fixed-timestep **frame pipeline** — the spine subsystems plug
into — plus the command buffer and event queue it needs. It is the prerequisite for
fanning work out into independent lanes.

## Decision

### 1. `engine.Sim` — the fixed-timestep frame

`Sim` owns the `World`, an ordered list of **systems**, a **command buffer**, an
**event queue**, and a list of **event handlers**. `Sim.tick()` is the single,
deterministic frame:

1. **run systems** in registration order, each given a
   `Context{ world, commands, events, dt, tick }`;
2. **flush** the command buffer into the world (apply deferred spawn/despawn/
   component-set), emitting `spawned`/`despawned` events;
3. **dispatch** every queued event (from systems + from the flush) to each handler,
   in order;
4. clear the queue; `tick += 1`.

Rendering is **not** part of the tick — it is render-side and cosmetic (ADR 0006),
driven separately from the deterministic sim.

### 2. Systems are free functions over a `Context`

`pub const System = *const fn (*Context) void;` — data-oriented (ADR 0001/0004),
iterating the world in cache order. A system **never mutates world structure
mid-iteration**; it records deferred changes into `ctx.commands` and may enqueue
events into `ctx.events`. **Registering a system is the seam** scripting (a
script-dispatch system) and physics (a collision/character-controller system) plug
into — no edits to shared orchestration.

### 3. Command buffer — deferred, transactional structural change

`CommandBuffer` records and later applies: **spawn** (reserves a handle immediately
so callers can reference it, attaches components at flush — matches ADR 0003
"resolves next tick"), **despawn**, and component **set** (Transform/Velocity in
v1). Flush order is deterministic. This is the backing for scripting's
`mana.spawn/despawn/set`, and it keeps despawn from invalidating an in-flight
system iteration. (Per-invocation transactional rollback on error — ADR 0003 §9 —
lands with scripting, which is what needs it.)

### 4. Events — a typed queue + handlers

`pub const Event = union(enum) { spawned: Entity, despawned: Entity, … };`
`pub const EventHandler = *const fn (*World, Event) void;`. v1 emits `spawned`/
`despawned` from the flush; `collision_begin`, `hit`, `death`, `room_enter` are
added by physics/scripting later. **Registering a handler is the seam** for
scripting event dispatch and for reacting to physics collisions.

### 5. Determinism preserved

System order, flush order, and dispatch order are all deterministic, so the state
hash is unchanged in structure. A `Sim` running only `movement` produces the **same
hash** as calling `movement` directly (the command buffer flushes empty, no events)
— the pinned determinism golden does not move.

## Consequences

- **Unblocks parallel lanes:** scripting (script-dispatch system + event handlers,
  backed by the command buffer), physics (collision system emitting events, a
  character controller recording movement commands), and render-integration each
  register against stable seams instead of editing `main.zig`.
- **Runtime simplifies:** the tick becomes "build a `Sim`, register systems, run" —
  the monolith turns into registration.
- **v1 scope (kept deliberately small):** command buffer covers spawn/despawn/
  Transform/Velocity; events cover spawned/despawned; systems run in one phase.
- **Named follow-ons:** the **timer wheel** and **transactional rollback on handler
  error** land with scripting (which needs them); **game-level events** (hit/death/
  room) with gameplay; an **input phase** with the platform port; a **render phase**
  hook with the gpu-port surface. Multiple ordered phases (pre/sim/post) are added
  only when a second phase is actually needed (no speculative structure).
