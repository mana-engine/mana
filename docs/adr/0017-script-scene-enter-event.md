# 0017. `on_scene_enter`: a per-scene bootstrap event

- Status: accepted
- Date: 2026-07-12

## Context

A script's `mana` accessors only work while a host is installed — i.e. *during* an
event dispatch (ADR 0015: the engine sets the host around each dispatch and clears it
after). The script module body runs at `loadScript` time, before any tick, with no
host, so `mana` calls there are inert. A package therefore has **no place to
initialize**: it cannot spawn its initial entities or schedule its first timer,
because every one of those needs a live host and no event fires when content loads.

This blocks issue #31 (Snake) concretely (issue #54): Snake must spawn the head and
food and start its move timer, but nothing dispatches a handler when the board loads,
so the package runs with zero entities.

The obvious shape — a once-per-sim `on_start` — is **wrong for a genre-agnostic
engine**: games have levels/scenes, and initialization is fundamentally *per scene*,
not per sim. A once-per-sim hook would need reworking the moment a second scene loads.
The engine's content unit is already the **scene** (`scene.zig`, `manifest.scenes`,
`entry_scene`), a scene is loaded into the world, and ADR 0003 §3 even reserved a
speculative `on_room_enter` ("room becomes active") for roughly this. The concrete,
non-speculative need is: *fire a bootstrap handler when a scene becomes active, with
the host live* — which naturally covers both today's single entry scene and future
level transitions.

## Decision

1. **Add `on_scene_enter(ev)` to the §3 event list**, fired **when a scene becomes
   active**: the entry scene at sim start, and (when scene switching lands) each
   subsequent scene load. `ev = { scene = <name> }` — the scene's `name` from its ZON,
   so a package with multiple scenes can branch its setup per level.
2. **This replaces the speculative `on_room_enter`.** The engine's unit is a scene;
   "room" was a genre-flavored guess for a concept that does not exist. A finer
   sub-scene "room" event, if a game ever needs one, is a later additive event — not
   presupposed now.
3. **No `self`.** Like the scene it accompanies, the handler is scene-level, not
   entity-level; `ev.scene` identifies it. (It is the first non-entity handler.)
4. **Fired with the host live**, during a tick's dispatch phase, so inside
   `on_scene_enter` the full `mana` surface works: `spawn` reserves entities (their
   components attach at the next flush, ADR 0003 §2), `after`/`every` schedule timers
   (#55), reads see the freshly-loaded scene. Effects follow the normal deferred
   model; nothing is special-cased except *when* it fires.
5. **Mechanism.** The `Sim` learns a scene became active via an explicit call (the
   runner invokes it after loading the entry scene into the world; future
   scene-transition code invokes it per switch). The event is queued and dispatched on
   the next tick with the host live — reusing the existing event/dispatch path, not a
   second code path. A single-scene package (Snake today) gets exactly one firing, at
   start: its bootstrap.
6. **Runs inside the §9 transaction** like every dispatched handler (throw → caught,
   logged, queued mutations rolled back; only OOM aborts). **Deterministic:** it fires
   at a fixed point relative to scene load, reads no wall clock or input, so the same
   package + seed + inputs yield a bit-identical state hash.

## Consequences

- **Issue #54 is resolved and scales to levels:** each scene initializes itself in
  `on_scene_enter` — spawn its entities, schedule its timers, set up its state. Snake
  bootstraps here (spawn snake + food, start the move timer); a multi-level game gives
  each level its own setup, branching on `ev.scene`. This is the foundation the other
  Snake gaps build on (#55 timers, #56 `set_position`, #57 input).
- **`on_room_enter` is retired** from the §3 table in favor of `on_scene_enter`
  (aligning the event with the engine's real content unit and terminology).
- **First non-entity handler** — the dispatch path grows a variant with an `ev` but no
  `self`. Small and contained (one `HandlerKey`, one `State.dispatch*`).
- **Committed to** firing `on_scene_enter` once per scene activation, host live, ahead
  of that tick's other events; and to the `Sim` exposing a "scene entered" entry point
  the runner (and future scene-switching) calls.
- **Explicitly not doing:** a once-per-sim `on_start` for cross-scene one-time setup
  (add if a concrete need appears — Snake has none); scene *switching* itself (the
  runtime still loads only the entry scene; this ADR defines the hook, not the
  transition machinery); an `on_scene_exit`/teardown counterpart (deferred until a
  concrete need); re-firing on hot reload of the handler table (a reload does not
  re-enter the scene — that would double-spawn).
