# 0006. Rendering: Vulkan gpu backend, offscreen-first

- Status: accepted
- Date: 2026-07-12

## Context

Time to make it visual. The `gpu` port already exists as a stub with a real null
backend and comptime selection (`-Denable-vulkan`); this ADR starts the real Vulkan
backend. Constraints from the vision: Vulkan never leaks above `gpu`; rendering is
cosmetic and excluded from the sim state hash; headless is the default; abstract
only where load-bearing (the port surface should emerge from a concrete backend,
not be designed speculatively); add dependencies only as a milestone needs them;
**stop and report on Zig 0.16 dependency churn** rather than patching around it.

Environment probe (this dev machine):
- Vulkan **loader present** (`vulkan-1.dll`), `vulkaninfo` present, GPU **AMD RX
  5700 XT**. Normal interactive local session (Parsec is only *installed* — hence the
  virtual display adapters — not streaming); a real window could open. Offscreen is
  chosen for headless-alignment and CI/verifiability, not out of display necessity.
- **No Vulkan SDK**: no `glslc`/shaderc (no GLSL→SPIR-V compiler) and no Khronos
  **validation layers** installed.
- **No SDL3** present.

## Decision

### 1. First backend is Vulkan, rendered **offscreen** — no window yet

The first milestones render into an offscreen `VkImage`, read it back, and write a
**PNG**. No swapchain, no surface, no SDL. Rationale:
- **Headless-first** — matches the engine's core thesis; rendering runs from files
  with no window, like the sim.
- **Verifiable by anyone** (including CI and me): the artifact is a PNG we can view
  and hash — independent of any display or session setup.
- **Defers SDL3** (one fewer churn source) until interactive windowing is the actual
  milestone.
- Exercises the hard part (instance/device/dynamic-rendering/pipeline/draw/readback)
  immediately.

Interactive SDL3 window + swapchain is a **later slice** (its own work, layering the
`platform` port over the same `gpu` backend), and a natural pairing with `--watch`
for live visual hot-reload.

### 2. Dependencies, added per milestone (all pre-authorized: vulkan-zig, VMA, SDL3, Tracy)

- **vulkan-zig now** (M1): generated Vulkan bindings, dynamically loading `vulkan-1`.
- **VMA later**, when hand-rolled allocation of a few resources gets painful (M1 does
  manual allocation of one image + one staging buffer — VMA is not yet load-bearing).
- **SDL3 later**, only for the interactive-window slice.
- **Tracy later**, for GPU/CPU profiling.

Each addition edits `build.zig.zon` (an "ask"-tier action) and lands with the slice
that needs it.

### 3. Boundary and selection

Vulkan types live **only** in `src/gpu`. The port exposes an engine-owned surface
(image/buffer/pipeline/command-list vocabulary) that is **discovered across M1–M3
and pinned here as it solidifies**, not designed up front. The Vulkan backend
compiles only under `-Denable-vulkan`; the **null backend stays the default**, so
`mise run check` and CI need no GPU and stay headless. Nothing above `gpu` changes.

### 4. Milestones (each a reviewable slice, verified by a PNG)

- **M1 — clear to PNG:** headless instance + device (no surface), an offscreen color
  image, clear it, copy to a host buffer, write a PNG. **No shaders.** De-risks
  vulkan-zig on Zig 0.16 and the whole memory/command/readback path.
- **M2 — triangle:** a graphics pipeline via dynamic rendering + a hardcoded
  triangle. Requires SPIR-V, so this milestone also settles **shader tooling**
  (below).
- **M3 — the scene:** draw the ECS `Transform`s as iso-projected quads
  (`core.math.worldToScreen`) → PNG. Add a **golden-image** regression test.
- **Later:** SDL3 window + swapchain (live view, `--watch` integration); VMA; a
  sprite batcher; Tracy zones.

### 5. Shader tooling (settles at M2, not M1)

M1 needs no shaders. At M2 we need GLSL→SPIR-V. Options, decided then: pin `glslc`/
shaderc as a mise tool, or install the Vulkan SDK, or commit pre-compiled SPIR-V for
the few built-in shaders. Preference: a **pinned `glslc`** invoked by a `build.zig`
step so shaders compile as part of the build (one source of truth), falling back to
committed SPIR-V if `glslc` can't be pinned cleanly.

### 6. Testing & determinism

Rendering is **cosmetic**: it never enters the sim state hash. Its correctness is
guarded by a **golden-image test** (hash/compare the rendered PNG) that runs **only
when `-Denable-vulkan` is set** — the default CI path stays GPU-free on the null
backend. **Validation layers** are treated as failures in debug builds *when
present*; they are absent on this machine (no SDK), so enabling them is a noted
follow-up (install the SDK / layers), not a blocker for M1.

### 7. Stop conditions

If vulkan-zig (or later SDL3/VMA) does not build against pinned Zig 0.16, **stop and
report options** (spike against the version the binding targets, carry a minimal
patch upstream, or wait) — no silent work-arounds.

## Consequences

- **Easier:** real GPU output that's verifiable headlessly and testable via golden
  images; SDL/window churn deferred; the port surface is grounded in a working
  backend instead of guessed.
- **Harder / accepted:** no on-screen window until the later SDL slice (offscreen PNG
  is the interim "view"); no validation-layer coverage until the SDK is installed;
  shader tooling is an open item resolved at M2.
- **Committed to:** vulkan-zig as the M1 dependency, an offscreen render→PNG path in
  `src/gpu` behind `-Denable-vulkan`, and the M1→M3 sequence. SDL3, VMA, Tracy, the
  sprite batcher, and validation layers are named follow-ons, each with its own slice
  (and ADR where it's a real decision).
