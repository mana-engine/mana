# src/core

**Responsibility:** Foundational, dependency-free layer — math (vec/mat, isometric
grid↔world↔screen transforms), allocator utilities, seedable RNG, and time /
fixed-timestep. This is the bottom of the module DAG.

**May import:** nothing above it. `core` imports only `std`. Everything here is
pure and deterministic — no I/O, no globals, no OS access. This is what makes the
simulation testable without a window or GPU.

**Imported by:** every other module.
