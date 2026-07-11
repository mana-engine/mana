# tests

**Responsibility:** Integration tests that exercise headless engine runs (load a
scene file → tick → assert state) and cross-cutting checks that don't belong to a
single module. Unit tests live in-file next to the code they cover; this directory
is for behavior that spans modules or drives a real content package.

- `fixtures/` — known-good ZON files for **golden-file tests**. They fail loudly on
  format drift and are updated only as an explicit, reviewed step ("update
  goldens"). Editing them is blocked by a Claude Code hook otherwise.

Key integration tests: `game.zon` manifest load, and the **determinism** test
(same seed + inputs ⇒ bit-identical sim state hash after N ticks).
