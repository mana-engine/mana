# src/platform

**Responsibility:** The OS-facing **port** — window/input (SDL3), the main loop,
and the fixed-timestep driver. Adapters are selected at comptime. The **headless**
adapter is the real default so the sim runs from files with no window; the **SDL3**
adapter (real OS window + keyboard/mouse) is opt-in via `-Denable-sdl3`.

The port vocabulary (ADR 0009) lives in `port.zig` — plain data, no OS type: `Key`,
`InputSnapshot` (sampled once per tick), `WindowConfig`. Each adapter implements the
same `Window` surface (`open`/`shouldClose`/`poll`/`size`/`close`) and is re-exported
from `platform.zig`, as `gpu` re-exports its backend's `Device`. A `Window` yields an
opaque native surface handle (`surfaceHandle() ?*anyopaque`) that the `gpu` port builds
a swapchain from (ADR 0012); `platform` and `gpu` never import each other, so the
handle is opaque on both sides and `engine` bridges it — no Vulkan type crosses here.

Layout: `platform.zig` (port face + adapter selection) · `port.zig` (vocabulary) ·
`headless/` (the default adapter) · `sdl3/` (the real OS adapter, `-Denable-sdl3`).
The SDL3 dependency (castholm/SDL, built from source) is lazy + flag-gated in
`build.zig[.zon]`, mirroring the vulkan/zlua deps — off by default, so `mise run
check` and `cross-win` stay window- and dependency-free. Phase 1 (this slice) is the
window/input adapter; the gpu-side Vulkan swapchain/present is phase 2.

**May import:** `core`, `std`, and SDL3 (only under `-Denable-sdl3`, kept inside this
module — never `gpu` or `vulkan`).

**Imported by:** `engine` only.
