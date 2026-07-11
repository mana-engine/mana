# src/platform

**Responsibility:** The OS-facing **port** — window/input (SDL3), the main loop,
and the fixed-timestep driver. Adapters are selected at comptime. The SDL3 adapter
is deferred; the **headless** adapter is the real default so the sim runs from
files with no window.

**May import:** `core`, `std` (and SDL3, once the adapter lands — kept inside this
module).

**Imported by:** `engine` only.
