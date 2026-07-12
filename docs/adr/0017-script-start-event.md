# 0017. `on_start`: a script bootstrap event fired once at sim start

- Status: proposed
- Date: 2026-07-12

## Context

A script's `mana` accessors only work while a host is installed — i.e. *during* an
event dispatch (ADR 0015: the engine sets the host around each dispatch and clears it
after). The script module body runs at `loadScript` time, before any tick, with no
host, so `mana` calls there are inert. This means a package has **no place to
initialize**: it cannot spawn its initial entities, seed content, or schedule its
first timer, because every one of those needs a live host and no event fires at sim
start.

This blocks issue #31 (Snake) concretely (issue #54): Snake must spawn the head and
food and start its move timer at the beginning, but nothing dispatches a handler at
start, so the package runs with zero entities. The existing §3 events all react to
things that happen *after* start (a spawn, a hit, a collision); `on_room_enter` is the
nearest fit but presupposes a room/level system that does not exist and carries an
entity `self` and a `room` payload a bootstrap has neither of.

ADR 0003 §3 fixes the event list, and §5 makes it additive within a version — a new
event is a surface change, hence this ADR.

## Decision

1. **Add `on_start()` to the §3 event list** — fired **once per Sim**, at the start
   of the simulation, before any other event. It is the package's bootstrap hook.
2. **No `self`, no `ev`.** Unlike the other §3 handlers, `on_start` is package-level,
   not per-entity — there is no entity or event that caused it — so it takes no
   arguments. It is the first entity-less handler; that is deliberate.
3. **Fired with the host live**, during the first tick's dispatch phase, before the
   tick's `spawned`/other events. So inside `on_start` the full `mana` surface works:
   `spawn` reserves entities (their components attach at the next flush, ADR 0003 §2),
   `after`/`every` schedule timers (fired from the timer phase onward, #55), reads see
   the initial world. Its effects follow the normal deferred model — nothing is
   special-cased except *when* it fires.
4. **Runs inside the §9 transaction** like every other dispatched handler: a throwing
   `on_start` is caught, logged, and its queued mutations rolled back; only OOM aborts
   the tick. (The circuit breaker is technically tracked for the key but moot — the
   event fires exactly once.)
5. **Deterministic:** it fires on tick 0 unconditionally, so the same package + seed +
   inputs still produce a bit-identical state hash. It does not read wall-clock or
   input.

`on_room_enter` stays **reserved** for a future room/level system (when rooms become a
real concept with an identifier and an owning script); `on_start` is the general,
room-agnostic bootstrap and does not depend on it.

## Consequences

- **Issue #54 is resolved** and the Snake bootstrap works: `on_start` spawns the snake
  + food and schedules the move timer. It is the foundation the other Snake gaps build
  on (#55 timers, #56 `set_position`, #57 input) — without a live-host start hook none
  of them can be reached.
- **A general lifecycle hook** every scripted package gets, not just Snake: seed
  entities, register timers, set up state. Genre-neutral (the engine fires it; what a
  package does in it is content).
- **First entity-less handler** — the dispatch path grows a variant with no `self`
  argument. Small, contained (one more `State.dispatch*` + one `HandlerKey`).
- **Committed to** firing `on_start` exactly once at tick 0 with the host live, ahead
  of that tick's other events.
- **Explicitly not doing:** an `on_stop`/teardown counterpart (deferred until a
  concrete need — sim teardown frees everything anyway); re-firing `on_start` on hot
  reload (a reloaded handler table does not re-bootstrap — that would double-spawn;
  revisit if a package needs a reload hook); `on_room_enter`/room semantics.
