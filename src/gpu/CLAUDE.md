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
- **A flagged `zig build` does NOT analyze *uncalled* fns; a flagged `zig build test`
  DOES.** `zig build -Denable-vulkan` only compiles decls actually reached from
  `main` — a `pub fn` in the Vulkan backend that nothing calls yet is never analyzed,
  so a compile error inside it slips the flagged *build* gate entirely. (Live example:
  #36's `Swapchain.deinit` shipped with a `catch |err| { _ = err; }` — an "error set is
  discarded" error under Zig 0.16 — because no caller existed until #29's `--play` loop
  forced its analysis.) The parity `comptime` block using `@hasDecl`/`@hasField` does
  **not** rescue you: it checks a decl *exists*, not that its body compiles. What
  *does* catch it: a `test` that references the fn, since `zig build test
  -Denable-sdl3 -Denable-vulkan` compiles **and runs** gated tests. So (a) run the
  flagged **test** build, not just the flagged build, before claiming a backend
  compiles; and (b) any Vulkan-only fn needs a test that reaches it — but a swapchain/
  present test must `return error.SkipZigTest` on `backend != .null_backend` (it drives
  a NULL surface handle the Vulkan backend rejects, and real present needs a display+GPU).
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
- **naga-cli build:** On this machine, `mise x cargo:naga-cli` builds with `zig cc`
  as Rust's linker (no system C compiler available). This is transparent to `mise run
  shaders`, but a fresh clone needs Zig installed for shader recompilation.
