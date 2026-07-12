# src/engine

**Responsibility:** Assembles the ports and the data-oriented core into a runnable
simulation. Headless operation is the default entry; a window is an optional
platform adapter, never a requirement. The fixed-timestep sim is pure and
deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

**May import:** `core`, `data`, `ecs`, `gpu`, `platform`, `physics`, `script`. `std`.
The `script` edge is live (ADR 0003, accepted): `sim` dispatches events to a Lua
handler table via `script_runtime.zig`, which is the only engine seam that reaches
into `script`. It compiles as a comptime no-op without `-Denable-lua`, so a default
build carries no Lua and stays bit-identical; no Lua/handle type leaks back up.

**Imported by:** `runtime`, `tools`.
