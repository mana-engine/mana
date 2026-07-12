# 0020. `mana.set_position`: write an entity's position from script

- Status: accepted
- Date: 2026-07-12

## Context

ADR 0003 §2 gives a script `position(h)` to *read* an entity's position and
`set_velocity` to change how it moves, but **no way to *write* its position**. A
grid game teleports entities to cells rather than integrating velocity — Snake (#31)
moves the head to a new cell and drags each segment to the cell ahead every move-step
(issue #56); the same is true of Pac-Man and Tetris. This cannot be expressed today,
so Snake's move timer errors on the missing `mana.set_position`.

ADR 0003 §6 requires an ADR for every `mana` addition, so this records the (small)
decision. The one choice is **a dedicated `set_position` vs. the generic
`set(h, component, value)`**: `set` (ADR 0003 §2, still unimplemented, #46) targets a
*named scalar data component*, but position is the built-in `Transform` (a `Vec3`), so
a dedicated accessor — the exact parallel of `set_velocity` — is the right fit, not an
overload of `set`.

## Decision

Add **`mana.set_position(h, x, y, z)`** (ADR 0015 host seam): a deferred mutation that
queues a `set_transform` on the command buffer (via the existing
`CommandBuffer.setTransform`) and applies at the next flush — the same deferred,
transactional model as `set_velocity`/`despawn`. A stale handle is dropped at flush;
with no Sim dispatching it is a no-op; it returns nothing (fire-and-forget). Because
the built-in `Transform` is currently just `pos`, it writes the whole transform; when
`Transform` grows (rotation/scale), `set_position` will preserve the other fields
(revisit then).

## Consequences

- **Snake's move loop works headlessly:** with `on_scene_enter` (0017) + timers (0019)
  + `set_position`, the snake actually advances one cell per tick and dies on the wall
  — the first game logic that *runs* deterministically. Turning still needs input
  (#57), but the simulation is live.
- **A general capability**, not Snake glue: any content that repositions an entity
  (grid teleport, warp, snap) uses it; genre stays in content.
- **Deferred + §9** like every other mutation — no mid-dispatch world write; a throwing
  handler/timer rolls its `set_position` back; determinism unchanged (it flows through
  the deterministic command buffer, nothing new in the state hash).
- **Not** a continuous-motion primitive — that is velocity/physics (ADR 0008/0011);
  `set_position` is a discrete write. **Not** the generic data-component `set` (#46),
  which remains its own follow-up for named scalar attributes.
