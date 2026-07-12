# 0016. Entity prototypes: named component templates for `mana.spawn`

- Status: accepted
- Date: 2026-07-12

## Context

`mana.spawn(prototype, x, y, z) → handle` (ADR 0003 §2) is the one deferred-mutation
accessor still unwired (issue #45); the read + `set_velocity`/`despawn` surface
already landed (#44, #48). ADR 0003 fixes the signature: the first argument is a
**named prototype**, not an inline component list — so `spawn` needs to resolve a
name into a set of components to attach. The engine has no such concept today: the
command buffer can reserve+attach a spawn, but only with a hardcoded
`transform`/`velocity` pair, and there is no registry of named templates.

This blocks issue #31 (Snake): the snake grows by spawning body-segment entities and
respawns food — all from Lua, with **no `src/` changes** in the package. Without
prototypes, a script cannot say "spawn a *segment* here."

Forces / invariants in tension:
- **Files are the source of truth; genre lives in content, not `src/`** (invariants
  #1, #6). Prototypes must be package ZON the engine interprets generically; the
  engine ships no built-in prototype and never references `games/**`.
- **One component-record shape.** A scene entity (ADR 0004 §6) is already "a `name`
  plus one optional field per built-in component." A prototype is the same thing
  minus a fixed position (the position comes from `spawn`'s `x,y,z`). Inventing a
  second, divergent record shape would be gratuitous.
- **Determinism** (ADR 0004 §8). Name resolution and spawning must stay
  deterministic and flow through the existing command buffer.
- **Data over Lua** (CLAUDE.md). A prototype is data (a diffable, hot-reloadable ZON
  template), not script — exactly where the guide says behavior-as-data belongs.

## Decision

1. **A prototype is a named, `EntityDef`-shaped template.** It reuses the scene
   entity schema (ADR 0004 §6): a `name` plus one optional field per built-in
   component. No new record shape. A prototype's `transform`, if present, supplies
   component *defaults*; `spawn`'s `x,y,z` overrides `Transform.pos` (a prototype
   without a `transform` gets one at the spawn point).

2. **Prototypes are package ZON, loaded into an engine-held registry.** A package
   declares prototype files the way it declares scenes — the manifest gains an
   optional `prototypes` list (parallel to `scenes`), each a ZON file of named
   templates. The runner parses them into a `PrototypeRegistry` (name → component
   set) it hands to the `Sim`. The registry is a generic string→components map; the
   engine knows the *format*, never any specific prototype. Prototype files are
   watched for hot reload like scenes (ADR 0005).

3. **`mana.spawn(name, x, y, z)`** resolves `name` in the registry through the host
   seam (ADR 0015): the engine-side `HostCtx` gains a pointer to the registry.
   - **Hit:** reserve an entity immediately (handle valid now, ADR 0003 §2), queue
     attaching the prototype's components with `Transform.pos = (x,y,z)`; resolves at
     the next flush.
   - **Miss (unknown name):** no entity is created; the call returns an invalid
     handle and the engine logs a warning. An unknown prototype is a content bug, not
     a crash — the honest-failure principle, like a stale handle dropped at flush.

4. **The command buffer's attach grows to a full built-in component set.** Today
   `attach` carries `?Transform`/`?Velocity`; it becomes the same optional-per-
   built-in-component payload an `EntityDef` describes (transform/velocity/health/…),
   so a prototype with any built-in component spawns correctly. The built-in set is
   comptime-fixed (ADR 0004 §4), so this is a fixed-width struct, not a dynamic bag.

5. **Determinism is preserved.** Registry lookup is a pure map read; the spawn flows
   through the existing deterministic command buffer (reserve order = free-list
   order; attach at flush). Nothing new enters the state hash; the determinism golden
   is unaffected.

## Consequences

- **`mana.spawn` becomes implementable** (issue #45) and **Snake can spawn segments
  and food** entirely from Lua + ZON — the last spawn-side blocker for #31 (the other
  is #46, named data components, for per-entity direction/grid state).
- **One entity-template concept** spans scenes and prototypes: the same ZON record,
  the same loader path, the same hot-reload story. A later, optional follow-on could
  express scene entities as prototype instances; not required here.
- **Command-buffer spawn** carries a full component set — a small widening of an
  existing struct, reused by any future multi-component spawn (native or script).
- **Committed to:** prototypes as package data only (no compiled-in templates); the
  registry threaded through `Sim` → host seam; `spawn` deferring like every other
  mutation.
- **Explicitly not doing:** prototype inheritance/composition or nested prototypes;
  runtime prototype creation from a script; overriding non-position components at the
  `spawn` call site (the ADR 0003 signature only carries a position — richer spawn
  parameters would need their own ADR + `mana` version bump). A prototype that needs
  a variant is a second named prototype.
- **Follow-up implied:** wiring the `prototypes` manifest field + loader + hot-reload
  watch is part of #45's implementation; #46 (data components) will let prototypes
  and `spawn` carry script-visible named data too.
