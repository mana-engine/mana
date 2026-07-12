# src/gpu

**Responsibility:** The renderer **port**. Defines the engine-owned GPU vocabulary
— `Device`, `Texture`, `Buffer`, `Pipeline`, `CommandList` (ADR 0010), described by
the plain-data descriptors in `port.zig` — and selects a backend at comptime via
build options. The one port operation, `renderScene`, is **backend-agnostic**: it
drives the selected `Device` through the vocabulary, so identical orchestration runs
on both backends. The **null backend** (`null/backend.zig`) is the real, testable
default — a CPU adapter that clears and software-rasterizes quads. The **Vulkan
backend** (`vulkan/backend.zig`, vulkan-zig + dynamic rendering, offscreen; ADR 0006)
compiles only under `-Denable-vulkan`.

The port also owns a **presentation surface** (ADR 0012): a `Swapchain`/`Frame` built
from a `SwapchainDesc` over an opaque, engine-owned `SurfaceHandle` — acquire → render
→ present, with `resize`/`AcquireStatus` recreation. The handle is a bare `?*anyopaque`
(the `platform` window's native pointer), **never** a `VkSurfaceKHR`; the Vulkan
surface is created and owned inside `vulkan/`. The null backend implements a real
headless swapchain; the Vulkan backend stubs it (`error.NotImplemented`) until the SDL3
windowing lane.

Layout: `gpu.zig` (port face + `renderScene` driver) · `port.zig` (vocabulary) ·
`types.zig` (`Quad`) · `null/` · `vulkan/`.

**May import:** `core`, `std`, and — uniquely in this codebase — Vulkan types.
**Vulkan must never leak upward:** nothing above `gpu` may import a Vulkan type.

**Imported by:** `engine` only.
