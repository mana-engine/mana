# games/sandbox

The first real content package and the engine's integration-test corpus. It is
**data, not code**: the engine has no compiled knowledge of it.

**Layout:**
- `game.zon` — manifest: name, version, entry scene, scene list, optional native
  module declaration.
- `scenes/` — scene definitions in ZON (`hello.zon` is the minimal starter).
- `scripts/` — Lua event handlers (added once the scripting API ADR lands).
- `assets/` — textures, audio, and other referenced files.

**Run it:** `mise run run -- games/sandbox`.
