# games/chronicle

The second content package — a genre-neutrality test. It reuses the exact same
built-in components as `games/sandbox` (`transform`, `velocity`, `health`) but
shapes them into a narrative/dialogue/inventory/save-archive feel instead of
sandbox's combat feel, to prove the engine carries no genre assumptions:

- **Dialogue:** `elder_sage` has no `velocity` (an NPC that stands still) and
  reuses `health` as a trust meter (`current`/`max` = trust earned / trust
  needed), not hit points.
- **Inventory:** `traveling_merchant` reuses `health` as a stock meter (stock on
  hand / stall capacity); `lantern_item`, `brass_key_item`, and
  `coin_pouch_item` are `transform`-only props — world items with no motion and
  no health at all.
- **Save/load:** `scenes/archive.zon` models a save-slot screen — slots are
  `health`-bearing (percent complete) or, for an empty slot, lack `health`
  entirely (`save_slot_3`). `archive_cursor` gives `velocity` to a UI element
  instead of a combatant, showing the component is not combat-specific either.

**Layout:** same shape as `games/sandbox` — `game.zon` manifest, `scenes/`,
`scripts/` (empty; this package uses no scripting, `script_api` omitted = 0),
`assets/`.

**Run it:** `mise run run -- games/chronicle`.
