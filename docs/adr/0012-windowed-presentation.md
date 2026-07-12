# 0012. Windowed presentation: gpu swapchain + platform window surface

- Status: accepted (port surface) / proposed (SDL3 + Vulkan swapchain impl, deferred)
- Date: 2026-07-12

## Context

The engine renders offscreen today: `gpu.renderScene` draws into a `Texture` and
reads it back to host RGBA8 (ADR 0006 M1–M3, ADR 0010 port surface). There is no way
to put pixels on screen in real time. The next milestone is a live windowed view —
ultimately a playable game (Snake) — which needs three seams that do not exist yet:

- **a presentation surface on `gpu`**: acquire an image, render into it, present it,
  and recreate it on resize — the swapchain concept ADR 0010 §1 explicitly left out
  ("no swapchain … because the renderer does not use them");
- **a window on `platform`**: an OS window that yields a surface-creation handle and a
  per-frame `InputSnapshot`. ADR 0009 fixed this vocabulary as design-only (`Window`,
  `poll → InputSnapshot`, the fixed-timestep loop) but wrote no code — `platform.zig`
  is still just the `Adapter` enum;
- **a real-time loop** that ties `poll input → tick → render → present` at a fixed
  timestep (ADR 0009 §1's accumulator).

This is the point the abstraction policy permits pinning the surface: there are now
**two concrete implementations** for each port (CLAUDE.md "second concrete impl
planned, or don't abstract") — the null backend / headless adapter (real, headless,
implemented **now**) and the Vulkan backend / SDL3 adapter (the next, supervised
lane). The design is grounded in how SDL3 + Vulkan actually present, so the surface is
concrete, not speculative:

```
SDL_CreateWindow                         → SDL_Window*        (platform owns)
SDL_Vulkan_CreateSurface(win, instance)  → VkSurfaceKHR       (gpu owns, internal)
vkCreateSwapchainKHR(surface, …)         → VkSwapchainKHR     (gpu owns, internal)
vkAcquireNextImageKHR → render → vkQueuePresentKHR
  VK_ERROR_OUT_OF_DATE_KHR / VK_SUBOPTIMAL_KHR ⇒ recreate the swapchain
```

Invariant #4 (Vulkan never leaks above `gpu`) is the hard constraint on the boundary:
the handle that crosses `platform → gpu` must be opaque and engine-owned, **not** a
`VkSurfaceKHR`.

This lane is the **dependency-free half**: it pins the port vocabulary and implements
everything needing no external dependency (the null swapchain, the headless window).
It adds **no** SDL3, writes **no** real Vulkan swapchain code, and leaks **no** Vulkan
type upward — each is a hard stop, deferred to the supervised SDL3/Vulkan lane.

## Decision

### 1. The `gpu` port gains a presentation surface (plain-data vocabulary)

`src/gpu/port.zig` pins the present vocabulary in the exact style of ADR 0010 —
plain-data descriptors + status enums, no backend types — and `gpu.zig` re-exports it:

- **`SurfaceHandle`** — an `extern struct { native: ?*anyopaque = null }`: an opaque,
  engine-owned handle to a **native OS window** that a backend builds a surface from.
  It is deliberately **not** a `VkSurfaceKHR`. Under SDL3 `native` is the
  `SDL_Window*`; the Vulkan backend calls `SDL_Vulkan_CreateSurface(native, instance,
  …)` **internally** to produce the `VkSurfaceKHR`, which is created and owned entirely
  inside `src/gpu/vulkan/`. `null` means no OS window — the headless/null path.
- **`PresentMode`** — `{ fifo, mailbox, immediate }`: `fifo` is vsync and the only mode
  Vulkan guarantees; a backend falls back to it when a requested mode is unavailable.
- **`AcquireStatus`** — `{ optimal, suboptimal, out_of_date }`, mirroring `VK_SUCCESS`
  / `VK_SUBOPTIMAL_KHR` / `VK_ERROR_OUT_OF_DATE_KHR`: `optimal` proceeds, `suboptimal`
  still presents but asks for recreation soon, `out_of_date` forces `resize` before the
  next render. This is the resize / minimize / display-change handling made explicit.
- **`SwapchainDesc`** — `{ surface, width, height, format, present_mode }`: the create
  descriptor (`format` reuses the existing `TextureFormat`).

The concrete **`Swapchain`** and **`Frame`** types are backend-owned and re-exported
from `gpu.zig` like `Device`/`Texture`. Both backends implement the identical surface:

```
Device.createSwapchain(desc: SwapchainDesc) !Swapchain
Swapchain.acquire(dev) !Frame            // Frame{ target: *Texture, index, status }
Swapchain.present(dev, frame) !AcquireStatus
Swapchain.resize(dev, w, h) !void        // recreate on resize / out_of_date
Swapchain.deinit(dev)
```

The scope is exactly what a windowed present path needs — acquire, render (into the
`Frame`'s `Texture`, reusing the existing `CommandList`), present, resize/recreate —
and nothing more (no multi-frame-in-flight sync objects, no per-image semaphore
vocabulary above the port; those stay inside the Vulkan backend when it lands).

### 2. The null backend implements it as a real adapter (now)

`src/gpu/null/backend.zig` gains a real headless `Swapchain`: it owns one CPU colour
`Texture`; `acquire` hands it out (`status = .optimal`, `index = 0` — the null chain
has one image and never goes out of date); the caller renders into it with the
existing null `CommandList`; `present` captures the image's pixels into an owned
buffer (so a headless run is observable) and is otherwise a no-op; `resize`
reallocates the target. An in-file test drives acquire → render (clear) → present and
asserts the captured pixels, then resizes and re-acquires — the parity harness for the
surface, GPU-free, in every headless/CI build.

### 3. The Vulkan backend stubs the same surface (deferred)

`src/gpu/vulkan/backend.zig` pins the identical `Swapchain`/`Frame`/`createSwapchain`
interface with every method returning `error.NotImplemented`. This keeps the flagged
build (`zig build -Denable-vulkan`) compiling and the two surfaces in lockstep, while
the real `VkSurfaceKHR`/`VkSwapchainKHR` bring-up — which needs SDL3 for the surface
and real acquire/present/sync code — is deferred to the supervised windowing lane.

### 4. The `platform` port gains a `Window` (vocabulary + headless adapter)

`src/platform/port.zig` pins ADR 0009's vocabulary as plain data with no OS type:
`Key` (a small engine-owned enum), `KeySet` (an `EnumSet(Key)` bitset), `MouseButtons`,
`InputSnapshot` (keys + mouse position + buttons + wheel, sampled once per tick), and
`WindowConfig`. `platform.zig` selects an adapter at comptime and re-exports its
`Window` (exactly as `gpu` re-exports its backend's `Device`). The `Window` surface:

```
Window.open(gpa, config: WindowConfig) !Window
Window.shouldClose(window) bool          // headless: caller-driven (requestClose)
Window.poll(window) InputSnapshot        // once per tick
Window.size(window) [2]u32
Window.surfaceHandle(window) ?*anyopaque // the opaque native handle for gpu
Window.close(window)
```

`src/platform/headless/adapter.zig` is a **real** headless `Window` (the default, no
OS dependency): no display, `shouldClose` is a caller-controlled flag (tick-budget /
`--watch` signal), `poll` returns a scripted `InputSnapshot` (empty unless a replay
harness injects one — ADR 0009 §4), `resize` simulates an OS resize (so the gpu
swapchain's `resize` is exercisable headlessly), and `surfaceHandle` returns `null`
(no OS window ⇒ the null swapchain's headless path). The **SDL3 adapter stays a
`@compileError` stub** (ADR 0002) — no SDL3 code is written here.

### 5. How the opaque handle crosses the boundary without leaking Vulkan

`platform` imports only `core`; `gpu` imports only `core` (+ Vulkan internally). They
**never import each other**, so they cannot share a Zig type directly. The handle is
therefore opaque on both sides, and `engine` (which imports both — the composition
root) bridges them:

```
const win = platform.Window.open(gpa, cfg);
const sc  = dev.createSwapchain(.{
    .surface = .{ .native = win.surfaceHandle() },  // ?*anyopaque → gpu.SurfaceHandle
    .width = win.size()[0], .height = win.size()[1],
    .format = .rgba8_unorm, .present_mode = .fifo,
});
```

`platform` yields a bare `?*anyopaque` (its own boundary type — an `SDL_Window*` under
SDL3, `null` headless); `gpu` wraps it in `SurfaceHandle` and, only inside the Vulkan
backend, turns it into a `VkSurfaceKHR`. No Vulkan type appears in `platform`,
`engine`, or `gpu`'s public face — verified: zero `@import("vulkan")` / `vk.*` hits in
`src/**` outside `src/gpu/`.

### 6. The real-time loop shape (design; not built here)

ADR 0009 §1 fixed the fixed-timestep driver — accumulate real elapsed time; while
`accumulator ≥ sim.dt`, `sim.tick(...)` and subtract `dt`; then render once with
`alpha = accumulator / dt`. Windowed presentation slots into it as:

```
while (!window.shouldClose()) {
    const input = window.poll();               // once per real frame (§4)
    accumulator += realElapsed();
    while (accumulator >= sim.dt) {             // 0+ fixed ticks
        sim.tick(ctx.with(input));              // input translated to command-buffer writes
        accumulator -= sim.dt;
    }
    const frame = swapchain.acquire(dev) catch |e| switch (e) {
        error.OutOfDate => { try swapchain.resize(dev, window.size()); continue; },
        else => return e,
    };
    render(frame.target, alpha);                // cosmetic; excluded from the state hash
    switch (try swapchain.present(dev, frame)) {
        .out_of_date, .suboptimal => try swapchain.resize(dev, window.size()),
        .optimal => {},
    }
}
```

`Sim.tick` is unchanged (ADR 0007); the accumulator only decides *how many times* it
runs against the wall clock, never *how* a tick computes, so the determinism golden is
untouched. Input is sampled **once per tick** into an immutable snapshot, so *given the
same input stream* a run is bit-identical (ADR 0009 §4). Building this loop — and
migrating `runtime/main.zig`'s `runOnce`/`runWatch` onto it — is the follow-on
implementation task (it needs a `Sim`, which `platform` does not import), not this ADR.

### 7. Not decided / deferred here

- The **SDL3 adapter** (real window + event pump + `SDL_Vulkan_CreateSurface`) and the
  **Vulkan swapchain** (`vkCreateSwapchainKHR`, image acquisition, present queue,
  per-frame semaphores/fences, recreation) — the supervised lane that adds the SDL3
  dependency (ADR 0002/0006 policy: ask first).
- Multi-frame-in-flight synchronization, swapchain image count, HDR/colour-space, and
  present-queue-vs-graphics-queue selection — internal to the Vulkan backend when it
  lands; none belong in the port vocabulary until a game needs a choice.
- Gamepad input and input-replay/demo recording (ADR 0009 named follow-ons).

## Consequences

- **Easier:** `gpu` and `platform` now have a fixed present/window contract for the
  SDL3+Vulkan lane to implement against; the null backend is a real, byte-checkable
  present harness in every headless build; the real-time loop has a named seam that
  reuses `Sim.tick` and the existing `CommandList` unchanged.
- **Harder / accepted:** the two gpu backends (and two platform adapters) must keep the
  present/window signatures identical — enforced for gpu by both re-exporting through
  `gpu.zig` and the flagged build compiling the Vulkan stub; the Vulkan `Swapchain` is
  `error.NotImplemented` until its lane, so `-Denable-vulkan` compiles but cannot yet
  present.
- **Committed to:** the vocabulary in §1/§4 as the pinned present/window surface;
  additions go through a new ADR. The opaque-handle boundary (§5) is the load-bearing
  rule that keeps invariant #4 intact once real windowing lands.
