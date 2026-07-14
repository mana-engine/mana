# src/script — working notes (loaded only when working here)

The scripting **port**: Lua 5.4 (via ziglua/`zlua`) decides *what* happens; the
engine executes *how*. This subtree is the ONLY place the `zlua` bindings may
appear; nothing above `script` sees a Lua type. The interpreter is selected at
comptime via `-Denable-lua`; **there is no default backend** — a build without the
flag compiles the module as a stub (no scripting API table), so ordinary and CI
builds are Lua-free. See `docs/adr/0003` (the Lua scripting API contract) and
`README.md`. The `mana` table (#5) and event dispatch (#6) are implemented; the
`engine` seam that drives dispatch is `src/engine/script_runtime.zig` (comptime
no-op without `-Denable-lua`). The rest of §2's live-`Sim` surface is still
deferred (see the last bullet below).

## Hard-won knowledge (ziglua / zlua / Lua 5.4)

- **ziglua on Zig 0.16:** the repo is `natecraddock/ziglua`; its module is now named
  **`zlua`** (dependency key `zlua` + `dep.module("zlua")`). `main` tracks Zig
  **master**, and a `zig-0.15.2` branch exists but there is **no `zig-0.16` branch**.
  The commit that builds on 0.16 is **`d2cb619`** ("Revert 'Update for Zig 0.17.0'
  (#222)", 2026-07-09) — pin that exact commit (a moving `main` ref will break when
  master advances, exactly like vulkan-zig). It **vendors Lua** (no system
  Lua/headers needed); select the version with the build option **`.lang = .lua54`**
  for Lua 5.4. Verified on Zig 0.16: `Lua.init(gpa)` / `lua.doString("return 1 + 1")`
  / `lua.toInteger(-1)` == 2 compiles and passes. Added **lazy** behind
  `-Denable-lua`; the backend lives in `lua.zig`, imported by `script.zig` only under
  the flag (comptime `if (build_options.enable_lua)`), so a default build never
  compiles it. zlua pulls transitive deps `aro` + `translate_c`.
- **`.lazy = true` still FETCHES the dep source on a default `zig build`** (into
  `zig-pkg/`); it only defers **compilation**, not the tarball fetch. So `zig fmt
  --check .` recurses into every fetched dependency's sources — and zlua's vendored
  `src/lib.zig` is **not** `zig fmt`-clean (trailing-comma/brace-spacing the upstream
  doesn't enforce), which fails the fmt gate on all platforms. Fix: the `fmt` /
  `fmt-check` mise tasks pass **`--exclude zig-pkg`** so we never format third-party
  vendored code. (vulkan-zig masked this only because its sources happen to be
  fmt-clean.)
- **A gated test in a comptime-conditionally-imported file is not auto-run.**
  `script.zig`'s `pub const lua = if (…) @import("lua.zig")` does **not** pull
  `lua.zig`'s tests into the module's test binary — test mode doesn't analyze the
  unreferenced decl. Add a dedicated `b.addTest` rooted at `lua.zig` (with the `zlua`
  import) under `-Denable-lua` so `zig build -Denable-lua test` actually runs it;
  verify it truly runs (force a wrong expected value once and watch it fail).
- **`mana.zig` / `handle.zig` (issue #5) piggyback on that same `lua_mod` test
  target** — no further `build.zig` changes needed. `lua.zig` does
  `const mana = @import("mana.zig");` and calls `mana.pushManaTable` for real
  (from `pushSandboxEnv`), which forces full analysis of `mana.zig`, which in
  turn genuinely uses (not just imports) `handle.zig`'s types — so both files'
  `test` blocks land in the same binary `lua_mod` already builds. `handle.zig`
  has no `zlua` import at all (pure index/generation packing); `mana.zig` is the
  only new file that touches Lua directly.
- **`script` intentionally does NOT import `ecs`.** The opaque handle bit layout
  (u32 generation high, u32 index low, packed into a 64-bit Lua integer) is
  duplicated in `handle.zig` rather than reusing `ecs.Entity.pack`/`unpack`,
  because ADR 0003 §4 pins that layout as part of the *scripting* ABI itself
  (own versioning story), and the module import DAG has `script` depend on
  `core` only. `handle.Registry` is `script`'s own, `State`-owned live-generation
  table (not `ecs.EntityAllocator`) — it starts empty and stays empty until a
  later engine → script wiring task begins mirroring real spawns/despawns into
  it via `setGeneration`; until then `mana.is_valid` is honestly `false` for
  every handle, which is correct (no live entities exist without that wiring).
- **Event dispatch returns a `DispatchOutcome`, it does not log (issue #6).**
  `State.dispatchSpawn`/`dispatchCollisionBegin` catch a throwing handler (ADR
  0003 §9), unwind the Lua stack, and return `.errored` — the *engine*
  (`script_runtime.zig`) logs it. This split is load-bearing: the Zig test runner
  counts any `.err`-severity `std.log` call as a failed test (see
  `lib/compiler/test_runner.zig`), so if `State` logged the error itself, the
  unit test that exercises the caught-error stack-unwind path would fail on the
  log alone. Returning the outcome lets that fragile path be asserted with no
  `.err` emission; `lastError()` carries the message across the unwind for the
  engine to log. Same reason `mana.zig` never invokes its `.err` branch in a test.
- **The live-`Sim` `mana` surface reaches the engine through the host seam
  (ADR 0015, `host.zig`).** `script` still imports `core` only; it cannot name
  `World`/`CommandBuffer`, so it declares a `core`-typed `Host` (opaque ctx +
  fn-pointer vtable) that `engine` fills for the duration of each dispatch
  (`script_runtime.zig` builds a `HostCtx` over the live world + tick-derived
  `now` + the sim's seeded `core.Rng` and calls `State.setHost` around dispatch;
  the `mana` closures capture a pointer to the `State`'s `host` slot). **Wired:**
  the reads `position`, `now`, `get` (named data components, ADR 0024),
  `random`/`random_int` (ADR 0022, #47), `is_walkable` (the scene tilemap's
  walkability grid, ADR 0035 — a *borrowed* `?*const Tilemap` threaded through
  `DispatchCtx`/`HostCtx`, mirroring `Sim.tilemap`/`Context.tilemap`, ADR 0027) and
  the authoritative `is_valid` (host when a Sim is dispatching, `handle.Registry`
  fallback otherwise); the deferred mutations `set` (named data components, ADR
  0024), `set_velocity`, `set_position`, `spawn`, `despawn`; the timers
  `after`/`every`/`cancel` (ADR 0019). With `get`/`set`/`is_walkable` the ADR 0003
  §2 `mana` v1 surface is **complete** — nothing remains deferred; any further
  addition needs its own ADR (ADR 0003 §5), same as this one. Named data components
  live in the ECS/World layer
  (`src/engine/data_components.zig`, a registered dense-column store, Option B),
  never in `script`; `get`/`set` reach it through the host seam like every other
  live-Sim accessor.
