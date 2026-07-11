# 0001. ECS: minimal custom over zflecs

- Status: accepted
- Date: 2026-07-12

## Context

The engine needs an entity-component-system for the data-oriented core. Two
candidates: bind the mature flecs C library via `zflecs`, or hand-roll a minimal
ECS. The architecture policy says abstract/adopt only where load-bearing and
avoid speculative dependencies; the core mandate is data-oriented design (entity
IDs, contiguous SoA component arrays, free-function systems, no virtual dispatch
in the hot path) and strict determinism.

The first bootstrap slice does not exercise an ECS at all — it runs a minimal SoA
sim directly — so the choice is about the trajectory, not an immediate need.

## Decision

Implement a **minimal custom ECS**: dense entity IDs, components as plain data in
contiguous SoA arrays, systems as free functions iterating in cache order. No
external dependency. The design is kept behind a small surface so a future adapter
(e.g. zflecs) could slot in via a new ADR if profiling ever justifies it.

## Consequences

- **Easier:** full control over memory layout and iteration order (cache-friendly,
  no archetype indirection we didn't ask for); trivial determinism; zero
  dependency and no exposure to Zig 0.16 binding churn; simplest possible thing
  that fits current needs.
- **Harder:** we own features flecs gives for free (queries, relationships,
  pipelines, change detection). We add them only when a real game package needs
  them, per the "no speculative flexibility" rule.
- **Committed to:** growing the ECS from the SoA sim seed in `src/engine`. Revisit
  via a new ADR the moment we want relationships/queries at a scale that would make
  a hand-rolled version a maintenance burden — that comparison should be a spike
  (build the same thing twice, measure, delete the loser), not a permanent
  abstraction layer.
