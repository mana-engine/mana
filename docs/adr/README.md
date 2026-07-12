# Architecture Decision Records

One file per decision: `NNNN-title.md` (zero-padded, incrementing). Each records
**context**, **decision**, and **consequences**. Write an ADR whenever a design
decision arises — a new dependency, a module boundary, a file-format change — and
reference it in the commit that acts on it.

Use `/adr <title>` to scaffold a new numbered record from the template.

The mandatory scripting-API ADR (ADR 0003) is **accepted** — `src/script` may be
built to that contract (as its own task that adds the ziglua dependency).

| ADR | Title | Status |
|-----|-------|--------|
| 0001 | ECS: minimal custom over zflecs | accepted |
| 0002 | Native dependencies deferred; ports ship as stubs | accepted |
| 0003 | Lua scripting API: table shape, events, handles, versioning | accepted |
| 0004 | Scene/entity component schema + ECS storage model | accepted |
| 0005 | File-watch port + hot-reload model | accepted |
| 0006 | Rendering: Vulkan gpu backend, offscreen-first | accepted |
| 0007 | Simulation frame pipeline: systems, command buffer, event dispatch | accepted |
| 0008 | Physics port + first adapter: hand-rolled 2.5D collision | proposed |
| 0009 | Platform port: window, input, fixed-timestep main loop | proposed |
| 0010 | gpu port surface: Device/Texture/Buffer/Pipeline/CommandList | accepted |
| 0011 | Character controller: move-and-slide via the command buffer | proposed |
| 0012 | Windowed presentation: gpu swapchain + platform window surface | accepted (surface + null/SDL3 window + Vulkan swapchain) |
| 0013 | SDL3 dependency + platform adapter (phase 1: window + input) | accepted |
| 0014 | Camera/projection is a configurable view; rendering stops hardcoding isometric | accepted |
| 0015 | Script↔engine host seam: how `mana` reaches the live Sim | accepted |
| 0016 | Entity prototypes: named component templates for `mana.spawn` | accepted |
| 0017 | `on_scene_enter`: a per-scene bootstrap event | accepted |
| 0018 | A game is data: prototypes are prefabs, scenes instance them, scripts query and drive | proposed |
| 0019 | Scripted timers: `mana.after`/`every`/`cancel` on the timer wheel | proposed |
