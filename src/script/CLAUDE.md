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
  `DispatchCtx`/`HostCtx`, mirroring `Sim.tilemap`/`Context.tilemap`, ADR 0027),
  `key_down` (the raw-device held-state keyboard poll, ADR 0021 §5 / ADR 0040 §2 —
  this tick's `platform.InputSnapshot` threaded through `DispatchCtx`/`HostCtx`
  exactly like `tilemap`, resolved against `platform.Key` via `stringToEnum`; an
  unknown name degrades to `false`) and the authoritative `is_valid` (host when a
  Sim is dispatching, `handle.Registry` fallback otherwise); the deferred mutations
  `set` (named data components, ADR 0024), `set_velocity`, `set_position`, `spawn`,
  `despawn`; the timers `after`/`every`/`cancel` (ADR 0019); and the device-agnostic
  action polls `action_down`/`action_axis`/`action_vector` (ADR 0040 §2) — each
  resolves an action *name* against the sim's borrowed `*const ActionMap`
  (`Sim.action_map`, threaded through `DispatchCtx`/`HostCtx` like `input`/`tilemap`)
  via the pure resolver (`engine.action_map.buttonHeld`/`axis1d`/`axis2d`), degrading
  to the neutral value with no map or an unknown/wrong-typed name. With `get`/`set`/
  `is_walkable`/`key_down` plus those three polls the ADR 0003 §2 `mana` v1 surface (as
  amended by ADR 0035 and ADR 0040 §2) is **complete**. The matching `on_action` edge
  *event* is not a `mana` member: `lua.zig`'s `dispatchAction` fires it, driven by the
  per-tick action diff in `sim.zig` (mirroring the `on_key` snapshot diff, ADR 0040 §2).
  Any further surface addition needs its own ADR (ADR 0003 §5), same as this one.
  Named data components live in the ECS/World layer
  (`src/engine/data_components.zig`, a registered dense-column store, Option B),
  never in `script`; `get`/`set` reach it through the host seam like every other
  live-Sim accessor.
- **`capture_input`/`cancel_capture` (ADR 0041 §1, issue #235)** arm/disarm the
  "press a key to bind it" primitive over the same host seam — `HostCtx.captureInput`
  (`src/engine/script_runtime.zig`) dupes the action name into `LuaRuntime.
  capture_armed` (gpa-owned, freed on disarm/`deinit`/a script hot-reload). The
  *interception* is not a `mana`/`Host` member: `src/engine/ui_dispatch.zig`'s
  `UiInput.keyEdge`/`padButtonEdge` peek `Runtime.armedCapture()` ahead of even
  nav/activate, and on the first qualifying **press** edge (a key or gamepad-button
  press — analog is v1-deferred) dispatch `on_input_captured({action, source})` via
  `LuaRuntime.dispatchInputCaptured`/`lua.zig`'s `State.dispatchInputCaptured` (mirrors
  `dispatchAction`'s two-string, no-`self` shape exactly) and clear the arm
  (`Runtime.clearCapture`, one-shot). `source` is device-neutral: a bare key
  `@tagName` (`"space"`, `"w"` — the same string `on_key` already uses), or
  `"pad_" ++` a `platform.GamepadButton` `@tagName` (`"pad_south"`, `"pad_start"`,
  `"pad_dpad_up"`) built at the call site since `GamepadButton` values are runtime,
  not comptime. `NoopRuntime` mirrors `armedCapture`/`clearCapture`/
  `dispatchInputCaptured` as inert no-ops so `ui_dispatch.zig` stays backend-agnostic
  under a default (no-Lua) build.
- **Reading *and writing* handler-table state is NOT `mana` surface, and does not move the
  version gate.** `State.handlerFieldInt`, its table-valued sibling
  `State.handlerFieldStrMap`, and that one's write twin `State.setHandlerFieldStrMap`
  (ADR 0041 §4 + its #247 amendment, issues #238/#247) are *engine → state accesses*, not
  script-callables: nothing is added to the `mana` table, so ADR 0003 §5's version stays
  1. This is the #135 persistence seam — content accumulates plain values in handler
  fields, an engine-side driver (`src/engine/input_override.zig`) reads them and owns the
  file write, because ADR 0003 §7 means a script can never touch the filesystem itself.
  `handlerFieldStrMap` **copies** both strings of every pair out with the caller's
  allocator (`State.freeStrMap` frees the result), so no returned string is a borrow into
  Lua memory a later collection could invalidate. Two gotchas it encodes: only slots
  *already* of type `.string` are read (`toString` coerces a number **in place**, which
  would rewrite the key slot and corrupt `lua_next`'s traversal), and the stack is
  restored by absolute height (`getTop`/`setTop`) rather than counted pops, since the
  traversal leaves a variable number of values behind on an early error return.
  The **write** direction exists because the read alone was a trap: the driver's field is
  the WHOLE override, so a script that cannot read the file back (no `io`, ever) starts
  each session claiming the player rebound nothing, and the next write makes that true
  (#247). `setHandlerFieldStrMap` replaces the field wholesale with a fresh table, copies
  every string into Lua's own heap (the caller's slice is borrowed for the call), and uses
  `rawset` in both directions — a `__newindex` on a content table must not intercept, or
  `error` out of, an engine write that is not `pcall`-wrapped. Its `NoopRuntime` mirror is
  inert, like every other accessor's. **Careful with `freeStrMap`:** it is the *backend's*
  free for a *read* result, and `NoopRuntime`'s version is a no-op (its read never
  allocates) — so an engine-side producer of pairs must ship its own free
  (`input_override.freeSources`), or a default build leaks.
- **Plain-data leaf types shared with the engine live in `types.zig`**, not in `lua.zig`.
  The reason is the comptime flag, not an import cycle (`lua.zig` importing `script.zig`
  back builds fine — verified): without `-Denable-lua`, `script.zig` resolves `pub const
  lua` to an empty `struct {}`, so a type declared in `lua.zig` is unnameable in exactly
  the build where the engine's inert `NoopRuntime` must still mirror the accessor
  signatures that use it. A leaf file both the stub and the backend import is the way out
  (the same split `engine` uses for `action_types.zig`).
