# tests

**Responsibility:** Integration tests that exercise headless engine runs (load a
scene file → tick → assert state) and cross-cutting checks that don't belong to a
single module. Unit tests live in-file next to the code they cover; this directory
is for behavior that spans modules or drives a real content package.

- `fixtures/` — known-good ZON files for **golden-file tests**. They fail loudly on
  format drift and are updated only as an explicit, reviewed step ("update
  goldens"). Editing them is blocked by a Claude Code hook otherwise.

Key integration tests: `game.zon` manifest load, the **determinism** test (same seed +
inputs ⇒ bit-identical sim state hash after N ticks), and **acceptance_scenarios.zig**
(ADR 0028 layer 2, issue #94) — replays every `games/<g>/scenarios/*.zon` staircase
file through the generic `engine.scenario` referee, one Zig `test` per mechanic, so a
red result names exactly which mechanic broke rather than "the game broke".
