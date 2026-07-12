# 0009. Platform port: window, input, fixed-timestep main loop

- Status: proposed
- Date: 2026-07-12

## Context

`platform` is one of the architecture's named ports (CLAUDE.md module DAG: "platform
→ SDL3 adapter (deferred); headless adapter is the real default") and already exists
as a stub (`src/platform/platform.zig`): a comptime-selected `Adapter` enum
(`headless`, `sdl3`) gated by `-Denable-sdl3`, with the SDL3 branch a
`@compileError` until its dependency lands (ADR 0002). Nothing about the port's
*vocabulary* is fixed yet — no window, no input, no main-loop shape — so there is
nothing for a future SDL3 adapter to implement against beyond the enum.

Two accepted ADRs already assume the pieces this one names but leave outside their
own scope:
- ADR 0007 fixes `Sim.tick` as the deterministic, fixed-`dt` frame (systems → flush
  → dispatch → advance timers) but explicitly excludes rendering and says nothing
  about who calls `tick`, at what cadence, or how OS input reaches it.
- ADR 0006 §1 names "SDL3 window + swapchain… a later slice, layering the `platform`
  port over the same `gpu` backend" and pairs it with `--watch` for live visual
  hot-reload — i.e. `platform` is expected to own the interactive main loop that
  drives both `Sim.tick` and rendering, not just a window handle.

Today `src/runtime/main.zig` hand-rolls two ad hoc loops instead: `runOnce` advances
a fixed `tick_steps` (60) with no wall clock at all, and `runWatch` polls the
filesystem on a millisecond sleep (`Io.sleep`) and reloads on change — genuinely
headless, no window, no input. This ADR fixes the port vocabulary a headless-first,
comptime-selected `platform` needs to (eventually) subsume both loops **and** drive
a real interactive session, without redesigning `Sim` or `gpu`.

Per "abstract only where load-bearing" and "no speculative flexibility" (CLAUDE.md),
this ADR is deliberately design-only: it fixes vocabulary and the headless
semantics that already are the default, and defers every line of SDL3 code to the
task that adds the dependency (ask first, per ADR 0002/0006).

## Decision

### 1. The port vocabulary (what `platform` owns)

- **Window**: `open(WindowConfig{ title, width, height, resizable })` → an opaque
  `Window` handle; `shouldClose(Window) bool`; `close(Window)`. No swapchain/surface
  vocabulary here — that is `gpu`'s concern once the SDL3 window slice lands (ADR
  0006 §1 pairs an SDL3 surface with the existing Vulkan backend); `platform` only
  owns the OS window object and its close/resize signals.
- **Input**: **polled, not callback-based** — one `InputSnapshot` sampled per frame
  via `poll(Window) InputSnapshot`, mirroring how `Sim.tick` consumes a `Context`
  rather than reacting to arbitrary callbacks. `InputSnapshot` is plain data: a
  keyboard bitset over an engine-owned `Key` enum, mouse position + button bitset +
  wheel delta. No gamepad in v1 (named follow-on). This keeps input **engine-facing
  data**, matching "Lua never iterates all entities per frame" / "engine executes
  *how*" — Lua never polls input directly; an engine-side system translates the
  snapshot into world state or command-buffer writes, and *that* can raise
  script-facing events (`on_room_enter`-style) later, per ADR 0003.
- **Main loop / fixed-timestep driver**: `run(Adapter, *Sim, RenderFn)` owns the
  classic accumulator pattern — accumulate real elapsed time; while the
  accumulator ≥ `sim.dt`, call `sim.tick(...)` and subtract `sim.dt`; then invoke
  `RenderFn` once with an interpolation `alpha = accumulator / sim.dt` for
  render-side smoothing between fixed steps. This is the seam ADR 0006 and ADR 0007
  already assume exists: `Sim.tick` stays exactly as ADR 0007 defined it (the loop
  calls it unchanged, zero or more times per real frame); rendering stays cosmetic
  and outside the tick, driven once per real frame with `alpha` as its only new
  input.

### 2. Adapters: headless is the port's real default, SDL3 is the first real adapter

- **`headless`** (already the default; this ADR fixes its *loop* semantics, not
  just its enum value): no OS window, `shouldClose` is driven by a caller-supplied
  condition (tick-count budget, EOF on a scripted input file, or a `--watch`-style
  external signal), `poll` returns an all-zero `InputSnapshot` unless a test harness
  injects a **scripted input stream** (a sequence of snapshots consumed one per
  tick — useful for input-replay tests, see §4). The accumulator either runs
  wall-clock-free (batch-advance `N` ticks back-to-back, matching today's
  `runOnce`) or paced by `Io.sleep` (matching today's `runWatch` poll cadence) —
  both are the same `run()` entry point with different `Adapter`-supplied timing
  sources, not two different loops.
- **`sdl3`** (deferred — first real adapter, unimplemented until its task lands):
  opens a real OS window, pumps real SDL events into `InputSnapshot` each poll,
  paces the accumulator against a real wall clock (`Io.sleep`/`Io.Duration`, per the
  root `CLAUDE.md` Zig-0.16 sleep note), and calls into the `gpu` port's (future)
  SDL3-paired swapchain to present once per real frame. Selecting it without the
  dependency continues to fail the build via the existing `@compileError`, per ADR
  0002's stub policy.

### 3. Engine/runtime wiring (target shape — not built in this lane)

`runtime/main.zig`'s `runOnce`/`runWatch` are the headless adapter's two timing
modes in disguise; the follow-on implementation task replaces them with
`platform.run(platform.adapter, &sim, render)`, parameterized by the same
`-Denable-sdl3` comptime flag `gpu` already uses for `-Denable-vulkan`. `engine`
composes an **input-translation system** (an ordinary ADR 0007 `System`) registered
like any other — it reads the current `InputSnapshot` (exposed on `Context` or a
small resource alongside `world`/`commands`/`events`) and writes intent into the
command buffer (e.g. a player-controlled entity's velocity). No orchestration code
changes to add it — the same seam ADR 0007 §2 already opened for scripting and
physics.

### 4. Determinism

- `Sim.tick`'s determinism (ADR 0007 §5) is **unchanged**: `platform.run` calls it
  the same way regardless of adapter, at the same fixed `dt`; the accumulator only
  decides *how many times* `tick` runs against real time, never *how* a tick
  computes. The pinned state-hash golden does not move.
- Frame pacing, wall-clock timing, and the render `alpha` are **cosmetic**
  (CLAUDE.md's physics/VFX invariant generalizes here): they affect only what is
  drawn between fixed steps, never sim state, and are excluded from the state hash
  — same boundary ADR 0006 already draws for rendering.
- Real human input is **inherently non-deterministic across sessions** — that is
  honest, not a defect. The port's contribution to determinism is narrower and
  concrete: input is sampled **once per tick** into an immutable `InputSnapshot`
  (never read mid-tick by multiple systems with different values), so *given the
  same input stream*, a run is bit-identical — which is exactly what makes the
  headless scripted-input-stream mode in §2 a legitimate input-replay/regression
  tool. Recording real sessions into a replayable stream (a "demo" file) is a named
  follow-on, not built here.

### 5. v1 scope boundary (kept deliberately small)

- **Vocabulary + headless semantics only.** `Window`, `InputSnapshot`, and
  `run()`'s accumulator shape are fixed as *types and contracts*; no SDL3 code is
  written, and the deferred branch keeps failing the build on purpose.
- **`runtime/main.zig` is not touched by this ADR.** `runOnce`/`runWatch` keep
  working as today; migrating them onto `platform.run()` is the follow-on
  implementation task once the vocabulary above is approved.
- **No gamepad, no input-replay recording, no SDL3 window/swapchain.** Named
  vocabulary or consequence, not implemented until a concrete game or milestone
  needs it (per "don't implement more \[port\] than a game exercises").

## Consequences

- **Easier:** SDL3 work (whenever it lands) has a fixed contract to implement
  against instead of inventing window/input/loop shape from scratch; `gpu`'s
  future SDL3-paired swapchain slice (ADR 0006 §1) and `engine`'s input-translation
  system both have a named seam; headless stays the real, always-tested default —
  zero churn to `mise run check`/CI, which stay GPU- and window-free.
- **Harder / accepted:** the eventual SDL3 adapter owns real OS event-pump
  complexity and platform-specific quirks (out of scope here); determinism given
  non-deterministic human input is only partially solved (single-sample-per-tick
  input, not full replay/recording) until a later ADR adds session recording.
- **Follow-on ADRs / tasks (unblocked, not in this one):** the SDL3 adapter
  implementation (window + input polling + swapchain pairing with `gpu`, its own
  Zig-dependency task per ADR 0002/0006 policy — ask first); migrating
  `runtime/main.zig`'s `runOnce`/`runWatch` onto `platform.run()`; the
  input-translation `System`; gamepad support; input-replay/demo recording for
  deterministic bug repro.
