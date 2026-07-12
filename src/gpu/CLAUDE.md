# src/gpu — working notes (loaded only when working here)

The renderer **port**. This subtree is the ONLY place Vulkan may appear; nothing
above `gpu` imports a Vulkan type (the engine-facing surface returns plain data —
e.g. RGBA pixels, `Quad`s). Backend is selected at comptime via `-Denable-vulkan`;
the **null backend is the default**, so ordinary and CI builds are GPU-free. See
`docs/adr/0006` (Vulkan, offscreen-first) and `README.md`.

## Hard-won knowledge (Vulkan / vulkan-zig / shaders)

- **vulkan-zig on Zig 0.16:** its `master` targets Zig 0.17-dev; use the maintainer's
  **`zig-0.16-compat`** branch (supported path, not a workaround). It needs a `vk.xml`
  registry — depend on **Vulkan-Headers** and pass
  `b.dependency("vulkan_headers",.{}).path("registry/vk.xml")` as the `.registry`
  option to `b.dependency("vulkan_zig", .{...}).module("vulkan-zig")`. Both deps are
  `.lazy = true` and referenced in `build.zig` only under `-Denable-vulkan`, so the
  default/CI build never fetches or compiles them. The backend lives under
  `src/gpu/vulkan/`, imported by `gpu.zig` only when the flag is set.
- **`std.DynLib` has no Windows implementation in Zig 0.16** (Windows hits its
  "unsupported platform" branch). To load a DLL on Windows, declare the kernel32
  externs yourself — `extern "kernel32" fn LoadLibraryW(name: [*:0]const u16)
  callconv(.winapi) ?windows.HMODULE;` + `GetProcAddress` + `FreeLibrary` — and use
  `DynLib` only on posix. The Vulkan loader (`vulkan-1`) is loaded this way at
  runtime, so no import library / Vulkan SDK is needed to build.
- **Comptime-guard the backend, and verify with the flag.** An API misuse reachable
  only from the Vulkan branch passes `zig build test` (test mode skips `pub fn main`
  *and* untaken comptime branches) yet fails `zig build -Denable-vulkan`. Guard
  backend-specific code with `if (gpu.backend == .vulkan) {...}` so a default build
  never analyzes it — and verify GPU work with `zig build -Denable-vulkan` + an
  actual render, never `test` alone.
- **vulkan-zig API shape:** `vk.Bool32` is `enum(u32){ false, true, _ }` — use the
  literals `.true`/`.false` in struct fields; `vk.TRUE`/`vk.FALSE` are bare
  `comptime_int`s that do **not** coerce to it. `vk.DeviceProxy`/`InstanceProxy`
  methods omit the device/instance handle (the proxy holds it) but `cmd*` still take
  `command_buffer` first; array params are Zig slices (`&.{x}`), and empty barrier
  arrays are `null`.
- **Shaders:** authored in WGSL under `src/gpu/vulkan/shaders/`, compiled to committed
  `*.spv` by naga (`mise run shaders`, pinned via `cargo:naga-cli`). The backend
  `@embedFile`s the `.spv` (declare it `align(@alignOf(u32))` so it can be cast to
  `[*]const u32` for `p_code`). glslc/GLSL isn't cleanly installable here (ADR 0006
  §5); a swap is trivial since the backend consumes SPIR-V.
