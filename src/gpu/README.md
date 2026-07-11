# src/gpu

**Responsibility:** The renderer **port**. Defines the engine-owned GPU vocabulary
(Buffer, Texture, Pipeline, CommandList) and selects a backend at comptime via
build options. The Vulkan backend (vulkan-zig + VMA + dynamic rendering) is
deferred; the **null backend** is the real, testable default used in headless
runs.

**May import:** `core`, `std`, and — uniquely in this codebase — Vulkan types.
**Vulkan must never leak upward:** nothing above `gpu` may import a Vulkan type.

**Imported by:** `engine` only.
