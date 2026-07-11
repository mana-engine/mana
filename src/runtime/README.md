# src/runtime

**Responsibility:** The `mana` runner **executable**. Parses a `game.zon`
manifest, loads the content package, drives the headless simulation, and
optionally loads a game's native module (a versioned C-ABI dylib). It knows the
manifest *format* but never any specific game.

**Import rule:** may import `engine` (and `core`/`data` as needed). **Nothing in
`src/**` — including here — may reference `games/**`.** A game is content passed in
at runtime, not code compiled in.

**Imported by:** nothing (top of the graph; it is the binary).
