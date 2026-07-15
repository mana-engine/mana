# 0041. SDL3 binding strategy: keep the thin engine-owned `@cInclude`, no wrapper

- Status: proposed
- Date: 2026-07-15

## Context

**What already exists.** The SDL3 dependency and its first binding decision are
*already made and shipped* — this ADR does not re-open them:

- **ADR 0013 (accepted, #33)** pulled in **[castholm/SDL](https://github.com/castholm/SDL)**
  (pinned tag `v0.5.2+3.4.12`), which ports SDL to the Zig build system and **builds
  SDL3 from source** (no system SDL, no prebuilt binary). It is `.lazy = true` in
  `build.zig.zon` and linked into the `platform` module **only** under `-Denable-sdl3`.
- The real adapter `src/platform/sdl3/adapter.zig` binds SDL via a thin, engine-owned
  `@cImport({ @cInclude("SDL3/SDL.h") })` and implements the ADR 0009 `Window` surface
  (`open`/`poll`/`size`/`resize`/`surfaceHandle`/`close`) method-for-method with the
  headless adapter. It maps SDL scancodes → the engine-owned `platform.Key` enum and
  returns the `SDL_Window*` as an opaque `?*anyopaque`.
- **ADR 0012 phase 2 (accepted, #36)** shipped the Vulkan swapchain/present path: the
  `gpu` backend declares `SDL_Vulkan_CreateSurface` / `SDL_Vulkan_GetInstanceExtensions`
  as `extern` C symbols itself and `build.zig` *links* the `SDL3` artifact into `gpu`
  **only** when both `-Denable-sdl3` and `-Denable-vulkan` are set — a build-level link,
  not a module import, so the DAG (`gpu → core`, never `gpu → platform`) and invariant
  #4 (Vulkan never leaks above `gpu`) hold.

So the **window / present** half of #12 / #28 is done: keyboard input, a real OS
window, and a `VkSurfaceKHR`-backed swapchain all work behind `-Denable-sdl3`
(`+ -Denable-vulkan`), with `mise run check` and `cross-win` green because both are
off by default. (The root `CLAUDE.md` "Deferred" section still lists SDL3 as a stub;
that line is stale relative to ADR 0013 and should be corrected when this ADR lands.)

**What is still open — and why this ADR exists.** ADR 0040 (accepted) pins the
data-driven action-map and the gamepad *design*: `platform.InputSnapshot` grows a
`GamepadButton` set, a `GamepadAxis` array (`[-1,1]` sticks, `[0,1]` triggers), and a
`pad_connected` flag; the SDL3 adapter is to sample these via `SDL_Gamepad` — ADR 0040
§5 explicitly says **"no new dependency — SDL3 is already the platform adapter"**. That
hands the physical gamepad layer (**#193**) to an implementation lane but does **not**
settle the *binding* question for the growing SDL surface. ADR 0013's rejection of a
third-party wrapper was scoped to the phase-1 window surface; as we now reach for a
**second, larger** slab of the SDL C API (gamepad buttons + analog axes + hotplug
events), the fork legitimately re-opens: **do we keep hand-binding SDL's C API through
the thin `@cInclude`, adopt a maintained Zig wrapper, or switch to a generated
translate-c binding?** Deciding this *before* #193 hand-binds more symbols is the point
of this ADR — it commits the strategy for all remaining SDL surface mana needs (window,
Vulkan surface, keyboard, gamepad) rather than letting each lane re-litigate it.

The surface mana actually needs from SDL is small and fixed by the ports above:

| Need | Issue | SDL C API (the whole surface) |
|---|---|---|
| Window + lifecycle | #12/#28 | `SDL_Init(VIDEO)`, `SDL_CreateWindow`, `SDL_DestroyWindow`, `SDL_GetWindowSizeInPixels`, `SDL_SetWindowSize/Title`, `SDL_Quit` — **done** |
| Keyboard + mouse | #28 | `SDL_PollEvent`, `SDL_GetKeyboardState`, `SDL_GetMouseState` — **done** |
| Vulkan surface | #12 | `SDL_Vulkan_CreateSurface`, `SDL_Vulkan_GetInstanceExtensions` (in `gpu`) — **done** |
| **Gamepad** | **#193** | `SDL_InitSubSystem(GAMEPAD)`, `SDL_OpenGamepad`/`CloseGamepad`, `SDL_GetGamepadButton`, `SDL_GetGamepadAxis`, the `SDL_EVENT_GAMEPAD_ADDED/REMOVED` events already drained by the existing `SDL_PollEvent` loop — **to bind** |

That is roughly a dozen more C symbols, all flat C functions over plain scalars — the
exact shape the existing `@cInclude` already handles for keyboard.

## Decision

**Keep the binding strategy ADR 0013 established, and reaffirm it for the whole
remaining SDL3 surface (gamepad included): a thin, engine-owned `@cImport`/`@cInclude`
over castholm/SDL's C headers, built from source, lazy + `-Denable-sdl3`-gated.** Do
**not** adopt a third-party Zig wrapper; do **not** introduce a generated translate-c
binding. Bind only the symbols the ports above name, behind the existing port
vocabulary.

Concretely, for the remaining work (#193):

- The SDL3 adapter adds `SDL_INIT_GAMEPAD` to its `SDL_Init` mask, opens player-1's
  `SDL_Gamepad` on the `SDL_EVENT_GAMEPAD_ADDED` event (and closes on `REMOVED`) inside
  the `SDL_PollEvent` loop `poll` already runs, and samples `SDL_GetGamepadButton` /
  `SDL_GetGamepadAxis` into the ADR 0040 `InputSnapshot` fields — mapping SDL's
  standardized `SDL_GAMEPAD_BUTTON_*` / `SDL_GAMEPAD_AXIS_*` to the engine-owned
  `GamepadButton` / `GamepadAxis` enums exactly as `key_map` already maps scancodes. A
  comptime test asserts the map covers every enum (mirroring the existing
  "sdl3 key map covers every port.Key" test). Axes are normalized to `[-1,1]` / `[0,1]`
  from SDL's `i16` range; **no dead-zone here** — ADR 0040 §4 applies dead-zone in the
  engine resolver, so the adapter stays a raw sampler.
- No SDL type crosses `platform`'s boundary (invariant #4 / ADR 0009): the adapter
  imports only the port vocabulary + SDL3, and yields plain-data `InputSnapshot`.
- No new dependency, no `build.zig.zon` change, no new build flag: gamepad rides the
  same `sdl` artifact and `-Denable-sdl3` gate already wired.

## Options considered

### Option 1 — Adopt a maintained third-party SDL3 Zig *wrapper*

Candidates in the current ecosystem (July 2026): **[Gota7/zig-sdl3](https://github.com/Gota7/zig-sdl3)**
(a higher-level idiomatic wrapper that layers *on top of* castholm/SDL as its
underlying C binding; states Zig 0.16 support), **[felixuxx/zsdl3](https://github.com/felixuxx/zsdl3)**
(thin zero-overhead bindings "without `@cImport`"), and the
**[allyourcodebase/SDL3](https://github.com/allyourcodebase/SDL3)** build-system port.

- **For:** idiomatic Zig error unions/enums instead of raw C; someone else maintains the
  binding surface; gamepad + Vulkan-surface helpers already wrapped.
- **Against (decisive):** it is a **common interface over a library with its own shape**,
  which CLAUDE.md forbids adopting ("Never build a common interface over libraries with
  different shapes"; "don't … adopt a third-party window abstraction" — ADR 0013's exact
  reasoning). mana already owns its port vocabulary (`Window`, `InputSnapshot`,
  `GamepadButton`) — a wrapper would be a *second* abstraction we translate through, pure
  overhead against our own. It adds a dependency whose Zig-0.16 maintenance we do not
  control (a moving target on pre-1.0 Zig — the same churn risk that forces our pinned
  `vulkan-zig`/`zlua`/`ztracy` commits), to save hand-binding ~a dozen flat C functions
  we already hand-bind for keyboard. The surface we need is tiny and stable; a broad
  wrapper is all the API we *don't* use. **Rejected** — same call as ADR 0013, now
  reaffirmed for the larger surface.

### Option 2 — Thin engine-owned `@cInclude` over castholm/SDL (**recommended, = status quo**)

Bind SDL's C API directly with `@cImport({ @cInclude("SDL3/SDL.h") })` inside the
adapter (and `extern` decls for the Vulkan-surface symbols in `gpu`), mapping only what
the ports need to engine-owned plain data.

- **For:** we own exactly the surface we use and nothing more (invariant "abstract only
  where we own the concept"; "bind the minimum surface behind the existing port"); it is
  **already implemented and green** for window/input/surface, so gamepad is a pure
  additive extension of a proven pattern, not a new mechanism; no new dependency, no new
  Zig-0.16 compat surface to track; the C API is SDL's **stable ABI** contract (SDL3
  ABI stable since 3.1.3), lower churn than any wrapper riding Zig-`std`. castholm/SDL
  **cross-compiles to `x86_64-windows` out of the box** (verified by ADR 0013's
  `cross-win` gate), so the gamepad addition inherits a working Windows path.
- **Against (accepted):** raw C ergonomics — manual `@intCast`, C enums, `SDL_GetError`
  for detail — and *we* own keeping the small symbol map correct (mitigated by the
  comptime coverage test). This is the deliberate trade CLAUDE.md prefers: own the
  load-bearing edge, keep the surface minimal.

### Option 3 — Generated translate-c binding committed to the tree

Run `zig translate-c` over `SDL3/SDL.h` once and commit the generated `.zig`.

- **For:** no per-build `@cImport` cost; a frozen, greppable binding.
- **Against:** translate-c over the full SDL3 header is a huge generated file (all of
  SDL, most unused) that we'd own and re-generate on every SDL bump — strictly worse
  than `@cInclude` (which generates the same thing transiently but scoped, and only for
  what we reference) with none of the wrapper's ergonomic upside. It also fights the
  "commit the recipe, not the generated artifact" rule (MEMORY: don't commit generated
  artifacts). **Rejected.**

### Sub-decision — build-from-source vs. link a system libSDL3

Settled by ADR 0013 and reaffirmed: castholm/SDL **builds SDL3 from source** through
the Zig build system. This is what makes hermetic cross-compilation to
`x86_64-windows` work with no system SDL, no prebuilt binary, and no per-developer SDL
install — the same model as our from-source `vulkan-zig`/`zlua`/`ztracy` deps. Linking
a system libSDL3 would break `cross-win` and hermeticity. Kept.

## Consequences

- **Easier:** #193 (gamepad) proceeds as a small additive change to a proven adapter —
  one `SDL_Init` flag, open/close on the hotplug events `poll` already drains, two
  sampler calls, and two enum maps with a comptime coverage test — behind the existing
  dependency, flag, and Windows cross-compile path. No new dependency to vet, pin, or
  keep Zig-0.16-compatible. Invariant #4 and the module DAG are untouched (adapter sees
  only port vocabulary + SDL; no SDL type escapes `platform`).
- **Harder / accepted:** mana keeps owning its thin SDL binding by hand — every new SDL
  need adds a few `@cInclude`-fronted symbols and a map entry rather than pulling a
  ready-made wrapper. This is intentional; the surface is small, stable (SDL ABI), and
  fully under our control.
- **Committed to:** the binding strategy for *all* remaining SDL3 surface (window,
  Vulkan surface, keyboard, gamepad, and any future slice) is the thin engine-owned
  `@cInclude` over the from-source castholm/SDL dep, lazy + `-Denable-sdl3`-gated. A
  future need to adopt a wrapper (e.g. if SDL surface grows large and unstable) would be
  its own ADR superseding this one.

## Next implementation steps (once accepted)

1. **#28 tail (window/present loop).** The window, input, and Vulkan swapchain are
   shipped; the remaining #28 work is migrating `runtime/main.zig`'s `runOnce`/`runWatch`
   onto the ADR 0012 §6 present loop (`poll → tick → acquire → render → present → resize`)
   under `-Denable-sdl3 -Denable-vulkan`. No binding change — pure composition-root
   wiring in `engine`/`runtime`. (Manual display+GPU acceptance step, per ADR 0012.)
2. **#193 (gamepad physical layer).** In `src/platform/port.zig`, add the ADR 0040 §5
   `GamepadButton` enum, `GamepadAxis` enum + `[N]f32` array, and `pad_connected: bool`
   to `InputSnapshot`; extend the **headless** adapter to expose injectable gamepad state
   (like its `scripted_input`) for deterministic tests. In `src/platform/sdl3/adapter.zig`,
   add `SDL_INIT_GAMEPAD`, open/close player-1's `SDL_Gamepad` on
   `SDL_EVENT_GAMEPAD_ADDED/REMOVED`, and sample `SDL_GetGamepadButton`/`GetGamepadAxis`
   into the new fields with `button_map`/`axis_map` + a comptime coverage test. This is
   the *physical* layer only; the data-driven `input.zon` resolver and `mana.action_*`
   surface (ADR 0040 §1–§4) are separate lanes consuming these fields.
3. **Docs.** Correct the stale root `CLAUDE.md` "Deferred" line (SDL3 is no longer a
   stub) when #193 lands.

## Rejected alternatives (summary)

- **Third-party Zig SDL3 wrapper (Gota7/zig-sdl3, felixuxx/zsdl3, …)** — a second
  abstraction over our own ports, an uncontrolled Zig-0.16 dependency, and mostly API we
  never use, to avoid hand-binding a dozen stable C functions. Against CLAUDE.md's
  "don't wrap libraries of a different shape" and "bind the minimum surface." (ADR 0013's
  call, reaffirmed for the larger surface.)
- **Generated translate-c binding in-tree** — a large committed generated artifact we'd
  own and re-generate, worse than scoped `@cInclude` with no upside.
- **Link a system libSDL3** — breaks hermetic `x86_64-windows` cross-compile and forces a
  per-developer SDL install; from-source (castholm/SDL) is kept.

Cross-references: #12/#28 (window + present — done), #193 (gamepad physical layer — the
lane this unblocks); builds on **ADR 0013** (SDL3 dependency + phase-1 window/input
adapter — the binding this reaffirms and extends), **ADR 0012** (windowed presentation:
gpu swapchain + the `SDL_Vulkan_CreateSurface` path, invariant #4 boundary), **ADR 0040**
(action-map + gamepad design; §5 hands #193 the SDL_Gamepad physical layer with no new
dep), **ADR 0009** (platform port vocabulary + `InputSnapshot`), and **ADR 0002**
(native deps deferred, one at a time behind their ports).
