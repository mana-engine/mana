# 0019. Scripted timers: `mana.after`/`every`/`cancel` on the timer wheel

- Status: proposed
- Date: 2026-07-12

## Context

`mana.after`/`every`/`cancel` (ADR 0003 §2) are the periodic driver a scripted game
needs — there is deliberately no `on_update`, so timers are how rules run over time
(Snake advances one cell per timer tick; issue #55). The engine already has a
deterministic timer wheel (`timer.zig`, `Sim.timers`) whose callback is a native
`*const fn(*World)` fired in `Sim.tick`'s timer phase, *after* event dispatch. Wiring
Lua onto it is not glue — it forces two real decisions (memory: games refine
fundamentals):

1. **The wheel's callback is a bare native function; a Lua timer must carry its
   handler reference.** The wheel doc already anticipates "scripting will wrap Lua
   closures behind it" — so the callback type must generalize.
2. **A Lua timer callback needs the full host live when it fires** (it calls
   `mana.spawn`/`set_position`/reads), but timers currently fire in the timer phase
   with no host installed and only a `*World` in hand — not the command buffer,
   prototypes, or `now` the ADR 0015 host seam needs.

## Decision

1. **Generalize the wheel callback to a closure** (a real fundamental improvement, not
   Lua-specific). `timer.Callback` becomes a tagged union:
   ```
   pub const Callback = union(enum) {
       native: *const fn (*World) void,               // engine callers, unchanged
       closure: struct { context: *anyopaque, func: *const fn (*anyopaque, *World) void },
   };
   ```
   Native timers use `.native` (so `Sim.after`/`every`'s signature and every existing
   caller are unchanged — `Sim` wraps internally); a Lua timer uses `.closure`. No
   function-pointer-to-`anyopaque` casts. `advance` fires either uniformly.
2. **Lua timers fire host-live, in the dispatch phase.** `Sim.tick` installs the host
   (via the script runtime, over the tick's `DispatchCtx`) around `timers.advance`, so
   a `.closure` Lua callback's `mana` calls reach the world/command buffer/prototypes;
   native callbacks ignore the host. Fired mutations queue on the command buffer and
   apply at the next flush — the same deferred model as every other `mana` mutation.
   Determinism is preserved: the wheel is already tick-derived and order-stable, and
   moving *when* Lua timers fire does not read a wall clock. (Native timers keep firing
   where they do; only the host installation is added around the advance.)
3. **`mana.every(interval, fn)` / `after(delay, fn)`** capture `fn` as a Lua registry
   reference (`luaL_ref` in the handler `State`) and schedule a `.closure` whose
   `context` is a small `State`-owned record `{ ref }` and whose `func` invokes that
   ref through the `State` (host live). They return an opaque timer handle (the wheel's
   generational handle, packed like an entity handle). **`mana.cancel(h)`** cancels the
   wheel entry and releases the ref.
4. **Reference lifetime.** The `State` owns its timer refs. A one-shot's ref is
   released after it fires; a cancelled timer's ref is released on cancel; all
   remaining refs are released on `State.deinit`. No ref leaks, no double-free (the
   wheel's generational handle already makes a stale `cancel` a no-op).
5. **§9 transaction per timer callback.** A Lua timer callback runs inside the same
   command-buffer mark/rollback as an event handler (ADR 0003 §9): a throwing timer
   leaves no trace and is logged; only OOM aborts. The circuit breaker treats timer
   dispatch like any handler key.

## Consequences

- **Snake's move loop works:** `on_scene_enter` schedules `mana.every(STEP, step)`, and
  `step` runs host-live each interval — reading positions, moving segments, spawning
  food. Timers are the periodic driver for every scripted genre (Tetris gravity,
  Pac-Man mode timers).
- **The wheel becomes closure-capable** — a general improvement any engine subsystem
  can use, not a Lua special case. `Sim`'s native timer API is unchanged.
- **Committed to** installing the host around `timers.advance` and to the `State`
  owning timer refs with deterministic release.
- **Explicitly not doing:** timer *coalescing/catch-up* changes (the wheel's
  at-most-one-fire-per-advance rule stands); passing arguments to timer callbacks
  (they take none, ADR 0003 §3); exposing native closures to content (Lua only).
- **Follow-up unblocked:** with `on_scene_enter` (ADR 0017) + timers, only
  `set_position` (#56) and input (#57) remain before Snake plays.
