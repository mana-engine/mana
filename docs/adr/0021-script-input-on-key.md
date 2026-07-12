# 0021. `on_key`: edge-driven keyboard input for scripts

- Status: proposed
- Date: 2026-07-12

## Context

Input reaches the sim as an `InputSnapshot` (ADR 0009): `Window.poll` samples the
held `KeySet` once per tick, native systems read it (`inputMoveSystem` maps keys to
velocity), and the same snapshot stream replays bit-identically. But a **script has no
way to read input** (issue #57): there is no input event in ADR 0003 §3 and no `mana`
accessor, so a Lua game cannot respond to the player. This is the last gap before
Snake (#31) is playable — the snake turns on the arrow keys, and today it cannot.

Two shapes are possible, and the choice matters:

- **Poll held state** — a `mana.key_down(key)` a handler/timer reads. Simple
  engine-side, but for a **grid game it loses quick inputs**: a tap-and-release
  between two discrete move-steps is gone by the time the move timer polls, so the
  turn is dropped. It also cannot distinguish a press from a hold (bad for
  press-actions like jump/rotate).
- **Edge events** — the engine dispatches a handler on each key *transition*
  (press/release). This captures the tap (the script buffers the intent) and cleanly
  expresses press-actions. It matches ADR 0003's event-driven model ("Lua reacts to
  events, not per-frame polling").

`platform.Key` is a `platform` type; a script (which imports `core` only) cannot see
it — but `@tagName` yields a neutral string (`"up"`, `"left"`, …), a scalar the
event can carry (ADR 0003 §3: payloads are scalars and opaque handles).

## Decision

1. **Add `on_key(ev)` to the §3 event list**, fired on each key **transition**:
   `ev = { key = <name>, pressed = <bool> }`, where `key` is `@tagName` of the
   `platform.Key` (`"up"`/`"down"`/`"left"`/`"right"`/`"w"`/…/`"escape"`) and
   `pressed` is `true` on press, `false` on release. **No `self`** — input is global,
   not per-entity (like `on_scene_enter`).
2. **The engine derives edges by diffing snapshots.** `Sim` remembers the previous
   tick's `InputSnapshot.keys` and, each tick, dispatches `on_key` for every key whose
   membership changed since last tick, in `Key`-enum order (deterministic). No OS or
   `platform` type crosses to `script` — only the key *name* string and a bool.
3. **Dispatched host-live in the dispatch phase, before timers.** So a turn the player
   pressed this tick is visible to the move timer that fires the same tick (Snake sets
   its pending direction in `on_key`, the timer reads it). Runs inside the §9
   transaction like every handler.
4. **Deterministic.** The `InputSnapshot` stream is deterministic (per-tick `setInput`
   or a recorded trace, ADR 0009); diffing is pure; so the same trace yields the same
   `on_key` sequence and the same state hash. Input itself stays out of the state hash
   (ADR 0009); the *effects* a handler applies are in it, as with any handler.
5. **Held-state polling is deferred.** A continuous-movement game (the platformer,
   #64: run while held; Tetris DAS) will want `mana.key_down(key)` — added when that
   concrete need lands, not now. Snake and press-actions need only edges.

## Consequences

- **Snake is playable:** `on_key` sets the pending direction on an arrow press; the
  move timer turns the snake. With `on_scene_enter` (0017) + timers (0019) +
  `set_position` (0020) + `on_key`, the full loop — bootstrap → input → timer → mutate
  — is closed, the loop every North-Star game reuses.
- **Press-actions across genres** (jump, rotate, hard-drop, interact) are expressed by
  `on_key` with `pressed == true`; releases are available for games that need them.
- **A general capability**, not Snake glue — the engine dispatches key transitions;
  what a game does with them is content.
- **Committed to** `Sim` tracking the previous input snapshot and dispatching key
  edges host-live before timers.
- **Explicitly not doing:** held-state polling (`mana.key_down`, deferred to #64);
  mouse/scroll/text input events (add when a game needs them); key *repeat* / DAS
  (a game builds that on edges + timers, or on held-polling later); remapping (content
  maps `on_key` names to actions itself).
