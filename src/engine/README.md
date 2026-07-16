# src/engine

**Responsibility:** Assembles the ports and the data-oriented core into a runnable
simulation. Headless operation is the default entry; a window is an optional
platform adapter, never a requirement. The fixed-timestep sim is pure and
deterministic (state in, state out). Genre-agnostic: no game-specific concepts.

**May import:** `core`, `data`, `ecs`, `gpu`, `platform`, `physics`, `script`, `ui`.
`std`. The `script` edge is live (ADR 0003, accepted): `sim` dispatches events to a
Lua handler table via `script_runtime.zig`, which is the only engine seam that reaches
into `script`. It compiles as a comptime no-op without `-Denable-lua`, so a default
build carries no Lua and stays bit-identical; no Lua/handle type leaks back up.

`render_ui.zig` is the UI-tree → GPU draw-list bridge (ADR 0034 §8, issue #133): it
turns a parsed `ui.Screen` (+ optional `ui.Host`) into flat `gpu.Quad` panels and
`gpu.SpriteQuad` label glyphs (reusing `text.zig`/the embedded font atlas), composited
through the same `gpu.captureFrame` sprites use — so a HUD renders headlessly. It lives
here, not in `ui`, because the glyph atlas/text layout are engine-tier, exactly as
`render.zig` is (the `ui` module stays a font-free `core + gpu + platform` interpreter).
`render_ui.worldHost` fills the `ui.Host` seam from a live `World` — a bound label name
resolves to the same-named data component (ADR 0024) on the first entity carrying it —
read-only and genre-neutral (the key comes from the game's HUD ZON, never from `src/`).

`ui_dispatch.zig` is the UI input-event → Lua bridge (ADR 0039, accepted; issue #134
phase B): `UiInput` holds the one active screen + focus state and turns synthetic
pointer/keyboard edges into `on_click`/`on_focus`/`on_activate` dispatches at the Sim's
handler table, applying the §3 "UI consumes input before gameplay" ordering. Event-driven
(never per-frame per-widget), opaque widget handles only, focus/hit state hash-excluded.
Because `gpu.captureFrame`/`renderFrame` bind ONE atlas, the runner uses
`sprite.merge` to stack the font glyph atlas below the scene sprite atlas, so a single
bound texture carries both game sprites and HUD label glyphs in one pass (issue #133).

`render_sprite.zig` and `sprite_atlas.zig` (issue #151) are size-driven splits off
`render.zig` and `sprite.zig` respectively, once each parent crossed the ~500-line soft
limit: `render_sprite.zig` holds the textured/animated sprite-quad path
(`projectSprites`), sharing `render.zig`'s projection math; `sprite_atlas.zig` holds the
CPU atlas packer (`Atlas`/`buildAtlas`/`merge`). Both re-export through their parent
(`render.projectSprites`, `sprite.Atlas`/`buildAtlas`/`merge`), so the public API is
unchanged — see each file's header for the split rationale.

`input_override.zig` is the rebinding **persistence driver** (ADR 0041 §4, issue #238):
it reads the bindings a script accepted off its handler table (`Runtime.
handlerFieldStrMap`) and writes them to the user-override `input.zon` that
`action_map.merge` layers over the package map. Persistence is engine-side Zig because
a script can never touch the filesystem (ADR 0003 §7) and must not — the engine owns the
file, the script only proposes data (invariant #1). The `bindings`/`bindings_revision`
handler-table contract is engine-generic: it names no action, key, or game; a package
declaring neither never writes. Cosmetic and hash-excluded, like the rest of ADR 0041.
The runner (`runtime/main.zig`'s `playLoop`) polls it at a tick boundary just *before*
the action-map watcher, so a rebind saves and applies within one iteration.

**Imported by:** `runtime`, `tools`.
