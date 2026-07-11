# tools

**Responsibility:** Editor and debug tooling — viewport, node-graph editor — built
with ImGui (zgui + imgui-node-editor). These are **disposable clients of the ZON
file format**, not part of the engine: they read and write the same text files the
headless engine consumes. Any feature that only works through a tool GUI is a
design bug.

**Import rule:** may import `engine` (and below). ImGui appears **only** here and in
debug overlays — never in game UI (game UI is content: ZON widget trees + Lua).

**Status:** stubs. Real editors are built when a concrete workflow needs them.
