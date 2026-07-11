# 0002. Native dependencies deferred; ports ship as stubs

- Status: accepted
- Date: 2026-07-12

## Context

The engine targets Vulkan (vulkan-zig + VMA), SDL3, Tracy, and Lua (ziglua). The
bootstrap pins Zig 0.16.0, a pre-1.0 release with active churn in both `std` and
third-party bindings. The first real slice — core math, the ZON serializer, the
`game.zon` manifest, and a headless tick loop — needs none of those libraries. The
project rules forbid adding dependencies without asking and require stopping (not
patching around) when a dependency breaks on the pinned Zig.

## Decision

Defer every native dependency. The `gpu`, `platform`, `audio`, `physics`, and
`script` ports ship as compile-clean **stubs**: their port shape and comptime
adapter-selection mechanism exist, but no backend is wired. Defaults are the
null/headless adapters (which are real, testable adapters). Selecting a deferred
backend (`-Denable-vulkan`, `-Denable-sdl3`) fails the build on purpose with a
clear message. Each real backend lands later as its own task with its own ADR.

## Consequences

- **Easier:** the bootstrap is green on Zig 0.16 with zero external-dependency
  risk; the headless, deterministic core is fully testable now; module boundaries
  and the comptime port-selection pattern are proven before any heavy dep arrives.
- **Harder:** nothing renders, opens a window, plays audio, or runs a script yet —
  those are explicitly out of scope until pulled in deliberately.
- **Committed to:** introducing SDL3, vulkan-zig, VMA, Tracy, and ziglua one at a
  time behind their existing ports, each justified by a concrete need. The Lua API
  table shape is a hard prerequisite (its own mandatory ADR) before `src/script`
  gains any surface.
