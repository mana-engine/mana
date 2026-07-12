# src/script — working notes (loaded only when working here)

The scripting **port**: Lua 5.4 (via ziglua/`zlua`) decides *what* happens; the
engine executes *how*. This subtree is the ONLY place the `zlua` bindings may
appear; nothing above `script` sees a Lua type. The interpreter is selected at
comptime via `-Denable-lua`; **there is no default backend** — a build without the
flag compiles the module as a stub (no scripting API table), so ordinary and CI
builds are Lua-free. See `docs/adr/0003` (the Lua scripting API contract) and
`README.md`. The API surface itself is deliberately unimplemented until its own
task — only the dependency is wired in (GitHub #3 spike).

## Hard-won knowledge (ziglua / zlua / Lua 5.4)

- **ziglua on Zig 0.16:** the repo is `natecraddock/ziglua`; its module is now named
  **`zlua`** (dependency key `zlua` + `dep.module("zlua")`). `main` tracks Zig
  **master**, and a `zig-0.15.2` branch exists but there is **no `zig-0.16` branch**.
  The commit that builds on 0.16 is **`d2cb619`** ("Revert 'Update for Zig 0.17.0'
  (#222)", 2026-07-09) — pin that exact commit (a moving `main` ref will break when
  master advances, exactly like vulkan-zig). It **vendors Lua** (no system
  Lua/headers needed); select the version with the build option **`.lang = .lua54`**
  for Lua 5.4. Verified on Zig 0.16: `Lua.init(gpa)` / `lua.doString("return 1 + 1")`
  / `lua.toInteger(-1)` == 2 compiles and passes. Added **lazy** behind
  `-Denable-lua`; the backend lives in `lua.zig`, imported by `script.zig` only under
  the flag (comptime `if (build_options.enable_lua)`), so a default build never
  compiles it. zlua pulls transitive deps `aro` + `translate_c`.
- **`.lazy = true` still FETCHES the dep source on a default `zig build`** (into
  `zig-pkg/`); it only defers **compilation**, not the tarball fetch. So `zig fmt
  --check .` recurses into every fetched dependency's sources — and zlua's vendored
  `src/lib.zig` is **not** `zig fmt`-clean (trailing-comma/brace-spacing the upstream
  doesn't enforce), which fails the fmt gate on all platforms. Fix: the `fmt` /
  `fmt-check` mise tasks pass **`--exclude zig-pkg`** so we never format third-party
  vendored code. (vulkan-zig masked this only because its sources happen to be
  fmt-clean.)
- **A gated test in a comptime-conditionally-imported file is not auto-run.**
  `script.zig`'s `pub const lua = if (…) @import("lua.zig")` does **not** pull
  `lua.zig`'s tests into the module's test binary — test mode doesn't analyze the
  unreferenced decl. Add a dedicated `b.addTest` rooted at `lua.zig` (with the `zlua`
  import) under `-Denable-lua` so `zig build -Denable-lua test` actually runs it;
  verify it truly runs (force a wrong expected value once and watch it fail).
