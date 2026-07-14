# 0037. GPU: Y-down NDC clip-space convention

- Status: accepted
- Date: 2026-07-14

## Context

Issue #148 exposed a **clip-space Y-convention collision** that was never written down as an invariant: the engine projects to **Y-down NDC** on the CPU (`src/engine/render.zig:71,179,285` — `screen.y=0 → ndc.y=-1`), the null CPU rasterizer honours that directly (`src/gpu/null/textured_raster.zig:92-93`), but **naga** compiles our WGSL under the WebGPU **Y-up** clip convention and injects `position.y = -position.y` into every vertex shader. On Vulkan with a positive-height viewport that was a double flip → whole frame inverted (visible only on the V-asymmetric ghost in #148).

The convention was verified to be **absent from every ADR, both CLAUDE.md files, and the gpu port surface** before PR #155 — a latent double-flip that survived because the null capture shared the Y-down assumption and every asset until the ghost was ~vertically symmetric.

PR #155 fixed the Vulkan backend (negative-height viewport, the standard `VK_KHR_maintenance1` reconciliation) and documented the chain in a `beginRendering` doc comment; this ADR **lifts the convention out of one function's comment into an architectural invariant** so it can't silently regress or get re-broken by a future backend.

## Decision

**The engine emits Y-down NDC** (`screen.y = 0 → ndc.y = -1`, mapping the screen top to NDC bottom). This is the **engine-wide invariant** that every `gpu` backend must preserve. Concretely:

1. **CPU projection is Y-down:** `src/engine/render.zig` (`projectPoint`/`projectSprites`), `src/core/math.zig` (`worldToScreen`), and the flat/isometric projection models all operate in a screen-space where `y = 0` is the top and `y` increases downward.

2. **Null backend honors it directly:** `src/gpu/null/textured_raster.zig` (`ndcToPxF`): `ndc.y = -1 → pixel row 0 = top`. The null rasterizer is a faithful test double, not an abstraction — it verifies the invariant deterministically.

3. **Vulkan backend must cancel naga's flip:** naga compiles WGSL under the WebGPU **Y-up** clip convention and injects `position.y = -position.y` into every vertex shader to retarget to Vulkan's Y-down clip space. Applied to our already-Y-down NDC that is a *second* flip. To cancel it, use a **negative-height viewport** (core since Vulkan 1.1; we target 1.3) in `beginRendering`: `y = height`, `height = -height`. This is the standard `VK_KHR_maintenance1` reconciliation and the only Vulkan-specific cost.

4. **Every new backend must verify the invariant:** the `gpu.captureFrame` orientation test (`src/gpu/gpu.zig`) asserts that an atlas's top row (v=0) composites to the output's top rows. The null backend runs this test in CI; any new backend (e.g. a real Vulkan GPU CI job via lavapipe) must pass the same test to prove Y-down NDC is preserved.

## Why Y-down, not Y-up?

The CPU projection lives in Y-down screen space (the natural frame-buffer convention: row 0 = top, y increases downward). Re-projecting to Y-up NDC at the CPU would add a coordinate flip there, introducing a second place to get wrong (or regress). Instead, the single canonical convention is **Y-down NDC end-to-end**, and each backend adapts: the null backend directly, Vulkan via a viewport flip (a no-op in terms of rendering cost, since culling is disabled and winding is a no-op).

## Consequences

- **Headless/null capture and live Vulkan render match identically,** guarded by the orientation test.
- **Y-convention bugs are caught headlessly**, not silently in production (the test is in CI for the default null build).
- **Future backends have a clear invariant to implement:** Y-down NDC is non-negotiable; the cost is backend-specific (naga's flip → viewport flip on Vulkan; direct on CPU, etc.).
- **Determinism is unaffected:** the Y-down convention is a rendering invariant, excluded from the sim state hash (cosmetic).

Cross-references: **#148** (the vertical-flip bug), **PR #155** (the Vulkan fix + orientation test), **ADR 0006** (Rendering: Vulkan gpu backend, offscreen-first), **ADR 0031** (Sprite rendering).
