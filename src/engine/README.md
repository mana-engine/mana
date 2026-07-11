# src/engine

**Responsibility:** Assembles the ports and the data-oriented core into a runnable
simulation. Headless operation is the default entry; a window is an optional
platform adapter, never a requirement. The fixed-timestep sim is pure and
deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

**May import:** `core`, `data`, `ecs`, `gpu`, `platform` (and `script` once its API
ADR lands). `std`.

**Imported by:** `runtime`, `tools`.
