# 0013. SDL3 dependency + platform adapter (phase 1: window + input)

- Status: proposed
- Date: 2026-07-12

## Context

ADR 0009 fixed the `platform` port vocabulary (`Window`, `InputSnapshot`,
`WindowConfig`, `Key`) and named the SDL3 adapter as the first real, non-headless
adapter — deferred until its dependency lands (ADR 0002's stub policy). ADR 0002
committed to "introducing SDL3 … behind [its] existing port" one dependency at a
time, each justified by a concrete need. The concrete need is now here: a real OS
window with real keyboard input (arrow keys) so a game (Snake) can be played, and a
native surface handle the `gpu` port will later turn into a `VkSurfaceKHR`.

This ADR covers **phase 1 only**: pull the SDL3 dependency in and implement the
window/input adapter. The gpu-side Vulkan swapchain/present wiring
(`SDL_Vulkan_CreateSurface` → `VkSurfaceKHR`) is **phase 2** (ADR 0012's impl track)
and is deliberately out of scope here.

## Decision

- **Dependency: [castholm/SDL](https://github.com/castholm/SDL), pinned to tag
  `v0.5.2+3.4.12`.** It ports SDL to the Zig build system and **builds SDL3 from
  source** (no system SDL, no prebuilt binary) — its `minimum_zig_version` is
  `0.16.0`, matching our pin. Chosen over higher-level Zig *wrappers* (e.g.
  `zig-sdl3`) because the port owns the C API only; the engine keeps its own thin,
  engine-owned `Window` surface (ADR 0009) rather than adopting a third-party window
  abstraction (CLAUDE.md: don't build/adopt a common interface over a library with a
  different shape). The artifact is named `SDL3` and installs its `SDL3/*.h` headers,
  so `@cInclude("SDL3/SDL.h")` resolves after `linkLibrary`.
- **Lazy + flag-gated, mirroring `zlua`/`vulkan_zig`.** The dep is `.lazy = true` in
  `build.zig.zon`; `build.zig` calls `b.lazyDependency("sdl", …)` and links the
  `SDL3` artifact into the `platform` module **only** under `-Denable-sdl3`. Default
  and CI builds (`mise run check`, `cross-win`) never compile SDL3 and stay window-
  and dependency-free. Selecting the flag flips `platform.adapter` from `.headless`
  to `.sdl3` at comptime and imports `src/platform/sdl3/adapter.zig`.
- **Adapter surface = the ADR 0009 `Window`, method-for-method with headless.**
  `open`/`close`/`shouldClose`/`poll`/`size`/`resize`/`surfaceHandle`. `poll` drains
  the SDL event queue (latching the OS quit request, accumulating the wheel delta)
  then samples `SDL_GetKeyboardState`/`SDL_GetMouseState` into an `InputSnapshot`.
  `surfaceHandle` returns the `SDL_Window*` as `?*anyopaque`.

## Consequences

- **No-leak invariant held (CLAUDE.md #4):** the adapter imports only the port
  vocabulary + SDL3 — never `gpu` or `vulkan`. `surfaceHandle` is `?*anyopaque`; the
  `gpu` port (not `platform`) will build the Vulkan surface in phase 2.
- **Default build unaffected:** flag off ⇒ no fetch-compile of SDL3, headless stays
  the tested default. Verified: `mise run check` and `cross-win` green; `-Denable-sdl3`
  compiles + links (SDL3 from source) and cross-compiles to `x86_64-windows[-gnu]`.
- **Follow-on (phase 2, not here):** `gpu`'s `SDL_Vulkan_CreateSurface` → swapchain
  present; migrating `runtime/main.zig`'s ad-hoc loops onto `platform.run()`; the
  engine input-translation system (all named in ADR 0009 §3/§5, ADR 0012 impl track).
