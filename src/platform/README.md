# src/platform

**Responsibility:** The OS-facing **port** — window/input (SDL3), the main loop,
and the fixed-timestep driver. Adapters are selected at comptime. The SDL3 adapter
is deferred; the **headless** adapter is the real default so the sim runs from
files with no window.

The port vocabulary (ADR 0009) lives in `port.zig` — plain data, no OS type: `Key`,
`InputSnapshot` (sampled once per tick), `WindowConfig`. Each adapter implements the
same `Window` surface (`open`/`shouldClose`/`poll`/`size`/`close`) and is re-exported
from `platform.zig`, as `gpu` re-exports its backend's `Device`. A `Window` yields an
opaque native surface handle (`surfaceHandle() ?*anyopaque`) that the `gpu` port builds
a swapchain from (ADR 0012); `platform` and `gpu` never import each other, so the
handle is opaque on both sides and `engine` bridges it — no Vulkan type crosses here.

Layout: `platform.zig` (port face + adapter selection) · `port.zig` (vocabulary) ·
`headless/` (the default adapter) · `sdl3/` (deferred, a compile stub today).

**May import:** `core`, `std` (and SDL3, once the adapter lands — kept inside this
module).

**Imported by:** `engine` only.
