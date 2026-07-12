# 0022. `mana.random`/`mana.random_int`: seeded RNG on `Sim`

- Status: proposed
- Date: 2026-07-13

## Context

ADR 0003 §2 promises `mana.random()` → a number in `[0, 1)` and
`mana.random_int(lo, hi)` → an integer, both "drawn from the sim's seeded RNG
(`core.Rng`), so runs are reproducible" — and §7 removes `math.random`/
`math.randomseed` from the sandbox for exactly this reason: any script
randomness must flow through the sim's own deterministic stream, never a
nondeterministic global. ADR 0015 already reserves both as host-seam vtable
entries (issue #47) but leaves them unimplemented: `src/script/host.zig` and
`src/script/mana.zig` carry `random`/`random_int` only in comments, and `Sim`
(`src/engine/sim.zig`) holds no `core.Rng` at all. `src/core/rng.zig` already
implements a splitmix64 generator (`Rng.init(seed)`, `Rng.next()`,
`Rng.float01()`) — issue #47 is wiring it through the seam, not building it.

This is a small, additive slice of the fixed ADR 0003 surface, so it gets the
lightweight ADR the contract requires (ADR 0003 §6/§5) rather than being
improvised inline — the same shape as ADR 0020 (`mana.set_position`).

Two choices need pinning:
1. **Where the seed lives and its default.** `Sim` has no scene/manifest seed
   concept yet, and threading one through would touch the scene-loading path for
   no game that currently needs it (CLAUDE.md "no speculative flexibility").
2. **The exact `random_int(lo, hi)` mapping.** ADR 0003 doesn't fix inclusivity
   or the bit-to-integer mapping, and this is a determinism contract: the exact
   sequence a given seed produces must never silently drift (ADR 0003 §5 — any
   change needs a version bump).

## Decision

### 1. `Sim.rng: core.Rng`, immediate reads (ADR 0015 pattern)

`Sim` gains a `rng: core.Rng = core.Rng.init(default_rng_seed)` field
(`src/engine/sim.zig`), where `default_rng_seed` is a fixed documented `u64`
constant (spells `"mana_rng"` in ASCII, chosen only to be a stable, recognizable
value — not cryptographically meaningful). A `Sim.setRngSeed(seed)` setter
overrides it before the first draw. This is the same "trivial constant, not
over-engineered" default the issue calls for; a per-scene/manifest seed is a
follow-up if a game ever needs reproducible-but-varied runs (no game does yet).

`mana.random`/`mana.random_int` are **immediate reads**, not deferred mutations:
unlike `set_velocity`/`spawn`/etc., they touch no `World`/`CommandBuffer` state —
their only side effect is advancing `Sim.rng`'s internal state, which is not
part of the state hash (`Sim.stateHash` delegates to `World.stateHash` only) and
needs no rollback-on-error semantics from ADR 0003 §9. This matches how
`position`/`now` are wired: `Host.VTable.random`/`random_int` resolve against the
live `Sim` the moment they're called, threaded through `DispatchCtx.rng: *core.Rng`
→ `script_runtime.HostCtx.rng` exactly like `now_seconds`.

### 2. `random()` → `f32` in `[0, 1)`

`mana.random()` returns `Rng.float01()` directly (already implemented, uses the
top 24 bits of `next()` — exact for `f32`). The host vtable's `random` fn returns
`f32` (not `f64`, despite ADR 0015's illustrative `f64` sketch) to match
`Rng.float01`'s actual precision; `mana.zig` widens it to a Lua number
(`f32 → f64` is a lossless implicit widen in Zig) when pushing.

### 3. `random_int(lo, hi)` → inclusive `[min(lo,hi), max(lo,hi)]`, locked mapping

`core.Rng` gains `intRange(lo, hi) -> i64`:

```zig
pub fn intRange(self: *Rng, lo_in: i64, hi_in: i64) i64 {
    const lo = @min(lo_in, hi_in);
    const hi = @max(lo_in, hi_in);
    const range: u64 = @intCast(@as(i128, hi) - @as(i128, lo) + 1);
    const scaled: u128 = @as(u128, self.next()) * @as(u128, range);
    const offset: u64 = @intCast(scaled >> 64);
    return @intCast(@as(i128, lo) + @as(i128, offset));
}
```

Decisions this pins:
- **Inclusive on both ends**: `random_int(1, 6)` can return `1` or `6`.
- **`lo > hi` is normalized, not an error**: the call is treated as the swapped
  range `[hi, lo]`. A script passing arguments in the wrong order gets a sane
  answer, not a crash mid-dispatch (ADR 0003 §9 would otherwise roll back the
  whole handler's queued mutations over an argument typo).
- **`lo == hi` always returns that value** — the general formula already
  produces this (`range = 1` ⇒ `offset` is always `0`), no special case needed.
- **Exactly one `Rng.next()` draw per call, regardless of argument order** — so
  the number of state advances a script causes never depends on whether it
  passed `lo, hi` or accidentally `hi, lo`. This matters because two scripts
  that both call `mana.random_int` the same number of times, even with some
  swapped arguments, must still consume the stream identically.
- **The mapping is Lemire's multiply-high trick**, not modulo: `next()` is
  widened to `u128`, multiplied by the inclusive `range`, and the top 64 bits of
  the 128-bit product become the offset. This is the standard bounded-random
  technique that avoids modulo's low-value bias, with **no rejection loop** (a
  rejection loop would consume a variable, seed-dependent number of `next()`
  calls — the opposite of the "one draw per call" guarantee above). It carries a
  theoretical, negligible bias for very large ranges relative to 2^64, which is
  irrelevant at any game-realistic range.
- **This exact formula is the version-stable contract** (ADR 0003 §5): a script
  seeing a specific seed sees a specific `random_int` sequence forever, locked by
  a known-value test (`core.Rng`'s `intRange` test for seed 0, range `[0,9]`).
  Any future change to the mapping is a breaking change requiring a version bump,
  same as changing the handle bit layout.

`core.Rng.intRange` lives in `src/core/rng.zig` (not duplicated in
`script_runtime.zig`), consistent with `float01`/`signedUnit` already living
there: it is pure, seed-only logic with no engine/script dependency, and its own
in-file tests are the natural home for locking the mapping.

### 4. Host seam wiring

`Host.VTable` (`src/script/host.zig`) gains:
```zig
random: *const fn (ctx: *anyopaque) f32,
random_int: *const fn (ctx: *anyopaque, lo: i64, hi: i64) i64,
```
with `Host.random()`/`Host.randomInt()` forwarders, mirroring every existing
vtable member. `script_runtime.zig`'s `DispatchCtx` gains `rng: *core.Rng`
(filled from `Sim.tick`'s `&self.rng`); `HostCtx` gains the same field and
implements `random`/`random_int` by calling straight through to
`cast(ctx).rng.float01()`/`.intRange(lo, hi)`.

`mana.zig` adds `manaRandom`/`manaRandomInt` Lua C functions with the same
closure-over-host-slot pattern every other accessor uses, and registers both in
`pushManaTable` and the sandbox-exposure name list. With no `Host` installed (no
Sim dispatching), `mana.random()` returns `0` and `mana.random_int(lo, hi)`
returns `lo` — the same graceful-degradation `mana.now`/`mana.position` already
use, never a raised error.

## Consequences

- **Content can roll dice deterministically:** loot tables, critical-hit checks,
  AI coin-flips, and procedural variation are all expressible in Lua without
  reaching for `math.random` (removed) or inventing an ad hoc PRNG in content —
  the exact gap ADR 0003 §7 flagged when it stripped the stdlib's nondeterministic
  RNG.
- **Determinism is unaffected by construction:** `Sim.rng`'s state is not part of
  `Sim.stateHash` (delegates to `World.stateHash` only), so adding the field does
  not change the pinned determinism golden; the *sequence* of draws is itself the
  determinism guarantee (same seed + same call trace ⇒ bit-identical draws),
  locked by round-trip tests at both the `core.Rng` level and through the full
  Lua → host → `Sim` seam.
- **A fixed default seed, not a per-scene one:** every `Sim.init` that never
  calls `setRngSeed` behaves identically to every other — useful for tests and
  for a first game that doesn't need seed variety. Threading a scene/manifest
  seed through is explicitly deferred to a follow-up ADR if a game needs it.
- **Not doing:** a general-purpose RNG API for native (Zig) systems — this ADR
  only wires the script-facing seam; native code can already call `core.Rng`
  directly. Not adding a "reseed from script" `mana` function — reseeding
  mid-run is not part of ADR 0003 §2 and would itself need a determinism story
  (excluded here as unnecessary complexity).
