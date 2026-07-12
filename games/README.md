# games

**Responsibility:** Content packages. A game is a directory of ZON files, Lua
scripts, node graphs, and assets with a `game.zon` manifest at its root — **not a
fork of the engine**. The engine runner is the executable; running a game is
`mise run run -- games/<name>`. A mod is another content package layered on top.

The engine never contains knowledge of any specific game. `games/sandbox/` is the
first real package: it grows alongside the engine as the proof that engine
features serve concrete needs, and doubles as the integration-test corpus.

`games/chronicle/` is the second package: a genre-neutrality test. It reuses the
exact same built-in components (`transform`, `velocity`, `health`) as sandbox but
shapes them into a dialogue/inventory/save-archive feel instead of sandbox's
combat feel — proof the engine carries no genre assumptions. See its README for
the specifics.
