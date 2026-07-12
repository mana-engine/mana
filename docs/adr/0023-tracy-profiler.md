# 0023. Tracy profiler behind `-Denable-tracy`

- Status: proposed
- Date: 2026-07-13

## Context

"Performance is first-class" and "Tracy hooks from day one" are vision invariants,
and ADR 0003 §6 requires script dispatch to run inside a Tracy zone with a per-frame
budget so a system consistently over budget is promoted to native by *measurement*,
not gut feel. Until now the sim carried a `TODO(tracy)` placeholder where that zone
belongs and no profiling existed.

We need frame/zone/plot/allocation instrumentation that:

- is **zero-overhead and dependency-free by default** — an ordinary or CI build must
  not compile, link, or fetch any profiler, and the sim must stay bit-identical
  (determinism test unaffected);
- keeps the profiler **contained** to one place, exactly as Vulkan is contained to
  `gpu`: nothing above the shim may name a Tracy type;
- reads the same at every call site whether or not profiling is compiled in.

**Why Tracy over an in-engine ImGui overlay.** An ImGui overlay would (a) pull `zgui`
into the runtime, which CLAUDE.md restricts to `tools/` + debug overlays and never
the headless runner; (b) only measure what we hand-code widgets for, on the same
thread we are trying to profile; and (c) give no frame timeline, per-zone flame
graph, lock/alloc analysis, or remote capture. Tracy is a purpose-built sampling +
instrumentation profiler with a separate viewer, nanosecond zones, memory tracking,
and plots — the right tool for "is script dispatch over its 0.5 ms budget?" It stays
behind a flag and out of shipping builds entirely, so it is not engine UI.

## Decision

### 1. Gating — a deferred, comptime-selected backend

A new `-Denable-tracy` build option (default `false`) mirrors `-Denable-lua` /
`-Denable-vulkan`:

- `build.zig` threads it into `build_options` as `enable_tracy`.
- The Tracy client is a **lazy** dependency in `build.zig.zon`, so a default build
  never *compiles* it. (As with the other lazy deps, `.lazy` defers compilation, not
  the tarball fetch; `fmt`/`fmt-check` already `--exclude zig-pkg` so vendored client
  sources never hit the fmt gate.)
- Under the flag, `build.zig` adds the `ztracy` import and links the static `tracy`
  artifact **into `core`**. Linking on the `core` module propagates transitively to
  every artifact that imports `core` (the runner exe and all per-module test
  binaries), so no call site needs its own link wiring.

### 2. The binding — zig-gamedev/ztracy

We use **zig-gamedev/ztracy**, the well-known Zig Tracy client binding, pinned to a
commit verified to build on Zig 0.16.0 (its `minimum_zig_version` is 0.15.1, but the
build graph and the vendored Tracy C++ client compile and link clean on 0.16.0,
including the Windows `ws2_32`/`dbghelp` link). It vendors the Tracy client (no system
Tracy needed), exposes the module `root` and the artifact `tracy`, and gates the
markers on its own `enable_ztracy` option, which we set only under `-Denable-tracy`.
Pinned to an exact commit like vulkan-zig/zlua, because zig-gamedev tracks Zig
releases and a moving ref would break on a toolchain bump.

### 3. The shim — `core/tracy.zig`

A thin, comptime-gated wrapper is the **only** module that names a Tracy type. It
imports `ztracy` inside a comptime-true branch, so a default build never resolves the
import. Surface:

- `tracy.zone(@src(), "name") -> Zone` with `Zone.end()` (use `defer z.end()`);
- `tracy.frameMark()`;
- `tracy.plot("name", value)`;
- `tracy.TracingAllocator` — wraps a child allocator; `allocator()` returns the child
  **unchanged** when the flag is off (identity, no vtable, zero overhead) and a
  tracing vtable when on.

Every entry compiles to nothing when `enabled` is comptime-false, so call sites are
identical in both builds.

### 4. Instrumentation

- **Frame + phase (runner `--play` loop, `src/runtime/main.zig`):** one `frameMark()`
  per iteration, and zones `poll`, `tick`, `render`, `present`.
- **Sim phases (`Sim.tick`):** zones `sim.systems`, `sim.flush`, `sim.dispatch`,
  `sim.timers`.
- **Script budget (ADR 0003 §6):** the `sim.dispatch` zone bounds all per-frame
  handler dispatch; finer per-call zones `script.dispatch`, `script.scene_enter`,
  `script.on_key`, and `script.timer` live in `script_runtime` (compiled only under
  `-Denable-lua`) so the per-frame Lua cost is directly measurable against the budget.
- **Memory:** the runner routes the engine allocator through `TracingAllocator`.
- **Plots:** `fps`, `tick_rate` (steps advanced this frame), `entities` (live world
  count), emitted from the `--play` loop.

### 5. Naming conventions

Zones use dotted, subsystem-prefixed lowercase labels (`sim.*`, `script.*`) or the
bare frame-phase name (`poll`/`tick`/`render`/`present`). Plots use lowercase
snake-ish nouns (`fps`, `tick_rate`, `entities`). Labels are comptime-static strings.

### 6. Script-time surfacing (deliberate)

There is **no** numeric "script time" plot. Emitting one would require reading a
monotonic clock inside `Sim.tick`, but the sim is pure/deterministic and holds no
`io` handle (Zig 0.16 moved monotonic time under `Io`). Script time is instead the
duration of the `sim.dispatch` and `script.*` **zones**, which Tracy times with its
own clock — exactly the ADR 0003 §6 "single Tracy zone with a per-frame budget". This
keeps the sim clock-free and determinism intact.

## Consequences

- **Easier:** real frame/zone/plot/alloc profiling on demand (`-Denable-tracy`),
  including the ADR 0003 §6 script budget, with a separate viewer and zero cost to
  shipping/CI builds. The `TODO(tracy)` in `Sim.tick` is discharged.
- **Harder / trade-offs:**
  - `core` now imports `build_options` (for the comptime flag). This is a build-time
    constant module, not a DAG dependency — the same exception `gpu`/`platform`/
    `script` already take — so "core imports only std" holds in spirit, but it is a
    real widening of `core`'s inputs and is called out here.
  - A new third-party dependency (ztracy + vendored Tracy client, transitively a
    `system_sdk` on macOS only). Contained to `core` and behind the flag.
- **Determinism:** all emitted data is cosmetic and excluded from the state hash;
  instrumentation adds no state and no clock read to the default sim. The pinned
  golden in `tests/determinism.zig` is unchanged.
- **Committed to:** keeping Tracy contained to `core/tracy.zig`; any new zone/plot is
  an additive call at a site, not a surface change needing an ADR. Bumping the ztracy
  pin follows the vulkan-zig/zlua playbook (exact commit verified against the Zig pin).
