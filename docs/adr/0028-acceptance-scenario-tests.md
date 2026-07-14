# 0028. Acceptance / scenario tests: a behavioral oracle atop the deterministic sim

- Status: accepted
- Date: 2026-07-13

## Context

The determinism test (`tests/determinism.zig`, `World.stateHash`) is the backbone of
the file-driven core: same seed + same inputs ⇒ a bit-identical state hash after N
ticks. But a hash answers only one question — **"did the output change?"** It is a
regression tripwire, and it is opaque: the pinned `0x65f2…` means nothing to a human,
and it cannot say whether the state it fingerprints is *correct*.

The gap is **behavioral correctness — "is the output right?"** A sim can be
**deterministically wrong**: Pac-Man walking through a wall, a Snake that never grows
when it eats, a score that never increments — each produces a perfectly stable,
perfectly reproducible hash. The hash guards against *drift*; nothing today guards
against *shipping a stably-broken game*. This is a genre-neutral engine fundamental:
every North-Star game (Snake → Pac-Man → Tetris → platformer → RPG, #62–65) needs it,
and none of them can assert it with a hash.

The replay machinery this builds on **already exists**. `src/engine/input.zig` +
`Sim.setInput` feed a fixed per-tick sequence of `InputSnapshot`s one entry per tick;
`Sim` is pure and deterministic; the world is queryable (built-in component accessors,
named data components via `mana.get`/`dataColumn`, entity counts, the event log). What
is missing is not a mechanism but an **oracle**: a way to state *what a correct run
looks like* and check it.

## Decision

Three complementary layers sit atop the deterministic sim. Each is strictly a
**referee**: the engine judges generic predicates and assertions; a game supplies the
genre-specific expectations as data. Nothing in `src/**` references `games/**`.

### Layer 1 — Universal invariants (engine, genre-neutral) — *lands in this PR*

Always-true predicates over world state that hold for *any* correct sim, whatever the
genre (`src/engine/invariants.zig`). Implemented this PR:

- **`nonfinite_transform`** — no `Transform.pos` is NaN or infinite.
- **`health_out_of_range`** — every `Health` satisfies `0 ≤ current ≤ max`, finite
  bounds, non-negative `max`.
- **`sparse_set_corrupt`** — every component column (built-in `SparseSet`s + each
  registered data column) is internally consistent: `dense`/`values` equal length, and
  each dense slot's entity index round-trips through `sparse` and names a live slot.
- **`nav_agent_in_wall`** — (only when the sim has a tilemap) no `NavAgent` rests inside
  a wall cell, judged over the *same* `Tilemap.isWalkable` topology `nav` paths over.

`check(world, ?tilemap) -> ?Violation` returns the first failure with its `Kind` +
offending entity; the caller adds the tick when reporting. Every predicate is phrased
over built-in components and the generic tilemap only — **no maze/snake/ghost/player
concept appears** (invariant #6).

**Cost gating.** `check` is a pure, allocation-free read pass and is **never called
from `Sim.tick`** — the hot frame pays nothing in any build *by construction*, so
there is no comptime flag and no per-tick overhead in a default/release build (CLAUDE.md
invariant #3). It is opt-in: a test, a debug harness, or the Layer-2 runner drives it
(per tick or once post-run). This was chosen over a `checkedTick` wrapper or a
`-Denable-checks` flag because "a function the hot loop never calls" is the simplest
zero-cost guarantee and needs no build-matrix entry.

**Deliberately *not* a Layer-1 invariant: a per-tick displacement cap.** "No entity
moved more than `speed·dt`" reads universal but is a **false positive** on teleport
movement (`mana.set_position`, ADR 0020 — how grid games like Snake advance a whole
cell per step). A correct velocity-aware bound needs per-entity velocity context *and*
previous-tick position history, which breaks the pure single-world `check` signature.
It is deferred to a follow-up; Layer 1 stays coarse and stateless on purpose.

### Layer 2 — Scenario acceptance tests (per-game, as DATA) — *follow-up this ADR authorizes*

A game ships `games/<g>/scenarios/*.zon`, each:

```
.{ seed, input_trace (per-tick keys), steps, expect: [ declarative assertions ] }
```

Assertions are **queries over post-run (and optionally per-tick) world state + the
event log**, built entirely on the *existing* surface: data components
(`mana.get`/`dataColumn`), entity count by tag/prototype, "event X fired", a component
field's value. The engine ships a generic `--scenario <file>` runner mode that loads
the package, replays the trace, evaluates each assertion, and reports **per-assertion
pass/fail** (plus the Layer-1 invariant check each tick). The **expectations live in
the game package** (invariant #6); the engine supplies only the generic evaluator +
replay + invariant checker.

**Design tenet — scenarios are an incremental, localizing staircase.** A scenario is
authored as an *ordered sequence of single-mechanic assertions*, each isolating one
fundamental, so a red result **pinpoints which mechanic broke** — "turning broke", not
"the game broke". A monolithic end-state assertion is discouraged: it tells you
*something* diverged, not *what*. Concretely, a Snake staircase reads: spawns with the
expected segments → advances one cell per step in its facing → an `on_key` turns it →
it reaches and eats the food → length increments on eat → self-collision ends the run.
The behavioral PoC in *this* PR (below) already demonstrates the staircase in Zig; the
Layer-2 work ports it to the data format.

**Every game ships its own suite — Snake is first-class, not a Pac-Man afterthought.**
The Layer-2 follow-up authors full Snake *and* Pac-Man scenario staircases; each
North-Star game contributes its suite as it lands, and the suite is the executable
acceptance definition the game's README already gestures at.

### Layer 3 — Fuzz / soak — *follow-up this ADR authorizes*

Replay many seeded-random input traces asserting **invariants + liveness/progress
metrics** (score *can* rise, dot count *can* fall, the sim never wedges), never exact
hashes. This finds the states hand-authored scenarios miss, while staying immune to the
brittleness of pinning an exact end-state.

### The determinism hash is retained

`stateHash` stays as the cheap tripwire beneath all three layers: it catches *any*
change for free, and the scenarios/invariants explain *whether a change is correct*.
They are complementary, not a replacement — this PR leaves the pinned golden untouched.

## Consequences

**Easier / gained**

- A readable, diffable, hot-reloadable **behavioral oracle** every game reuses; a
  failure names the broken mechanic instead of a hex delta.
- Layer 1 lands now at zero hot-loop cost and immediately catches a class of stable-but-
  broken states (NaN positions, impossible health, store corruption, agent-in-wall).
- Scenarios are content (invariant #1/#6): authored, reviewed, and evolved with the
  game, never compiled into `src/`.

**Harder / owned**

- **Authoring + maintenance cost.** Scenarios must be written and kept current as
  content changes. Mitigation: prefer **coarse invariants and single-mechanic staircase
  assertions** over exact end-states, which are brittle and re-opaque.
- The Layer-1 invariant set (kinds, order, nav-in-wall topology) is now a small contract;
  extending it is cheap but changing its meaning needs care.

**Alternatives considered**

- **Hash-only (status quo).** Opaque; proves *change*, never *correctness*. Kept as the
  tripwire, rejected as the whole answer.
- **Full-state golden snapshot.** Still opaque (a diff of raw state is not a spec) and
  *more* brittle than a hash — every incidental change churns the golden.
- **Visual / screenshot tests.** Needs a GPU and a window; breaks headless-first
  (invariant: engine runs from files alone). A behavioral oracle must be headless.

**Explicitly not doing in this PR (follow-ups this ADR authorizes)**

- The `games/<g>/scenarios/*.zon` **format** and the `--scenario` runner mode (Layer 2).
- **Fuzz/soak** harness (Layer 3).
- Full **Snake and Pac-Man scenario suites** in the data format.
- A **velocity-aware displacement invariant** (needs history; see Layer 1 note).

This PR lands **Layer 1** (the genre-neutral invariants) plus a **behavioral PoC**: a
Zig integration test that drives the real `games/snake` package via the existing
primitives (input-trace replay + state queries + the invariant checker) as an
incremental staircase, proving the oracle concept on a real game without yet building
the ZON scenario format.
