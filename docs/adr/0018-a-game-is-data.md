# 0018. A game is data: prototypes are prefabs, scenes instance them, scripts query and drive

- Status: accepted
- Date: 2026-07-12

## Context

Building Snake (#31) surfaced that we lacked a coherent answer to *"what is a game
made of, and where does each part live?"* — so gaps were being filed and patched one
at a time (bootstrap event, timers, input, `set_position`, data components) without a
model to fit them into. Stepping back across genres (Snake starts with a few segments
+ food; Tetris with a well and a random first piece; an RPG with a player that already
has an inventory) shows the shared structure and forces the decision this ADR records.

Game engines split into two families for "what is a player/enemy/level":

- **Scene-graph / OO** (Godot, Unity classic, Unreal): the unit is a *node tree*; a
  character is a reusable sub-scene with a **script attached per node**; you compose by
  *nesting*; identity is node paths/groups.
- **Data-oriented ECS** (Bevy, flecs, Unity DOTS): the unit is a *flat entity* = a set
  of components; the reusable template is a **prefab/bundle**; a scene is *serialized
  entity+component data*; behavior is **systems over queries**; identity is **marker/tag
  components**.

mana's own invariants **mandate the ECS/data family and forbid the scene-graph one**:
"Core is DOD… no behavior-objects, no observers/virtual dispatch in the hot path"
(no per-node scripts); "Lua never iterates all entities per frame… a per-entity-per-
frame Lua callback is wrong" (behavior is native systems + *one* event-driven rules
script, not a script per entity); "prefer data over Lua" (the player/enemy/level is
data the engine interprets). We already have the halves — prototypes (ADR 0016) and
scenes (ADR 0004) — but no decision tying them, scenes cannot yet *instance* a
prototype, and a script has no way to *reference* a data-declared entity.

## Decision

**A game in mana is data interpreted over a flat DOD-ECS; scripts are rules, not
entity behavior.** Concretely:

1. **Prototype = prefab.** A named component *bundle* (ADR 0016) is the reusable
   "player / enemy / food / piece" unit — the ECS analogue of a Godot sub-scene or a
   Unity prefab, but a flat component set, not a node tree. It has no script and no
   children.
2. **Scene = a level = an arrangement of prototype *instances*.** A scene entity
   becomes "instance prototype `P`, override these fields (at least position)", instead
   of only an inline component list (ADR 0004 §6 gains prototype-instancing; inline
   entities stay valid). This is Godot/Unity/Bevy *instance-with-overrides*, mapped to
   a flat entity. Snake's initial segments, Tetris's board, the RPG's starting party
   are all **scene data** this way — not script-spawned.
3. **State lives in components**, in the World's SoA columns: the comptime built-ins
   (ADR 0004 §4) *and* **named data components (#46)** for attributes a game defines —
   inventory, a snake's heading, a Tetris piece's kind. This is why #46 is core, not a
   Snake curiosity: per-entity *state* is data on the entity, queryable and hashed.
4. **Identity = a tag** (a marker the engine indexes), so a script can *find*
   data-declared entities. Entities carry an optional tag in scene/prototype data
   (`"head"`, `"food"`, `"player"`); the engine keeps a tag→entities index; `mana`
   gains a **query** accessor (`find`/`find_all` by tag) — the ECS marker-component
   pattern (Bevy/flecs), the bridge that makes "initial state as data" usable from
   rules. Queries are a *wiring/event-time* tool (grab handles at `on_scene_enter`,
   store them in a Lua table, drive them) — **never** a per-frame scan.
5. **Behavior split — what goes where:**

   | Concern | Home | ECS form |
   |---|---|---|
   | Reusable template | `prototypes.zon` | named component bundle (prefab) |
   | Level / start arrangement | `scene.zon` | prototype *instances* + overrides + tags |
   | Entity state (pos, hp, inventory, heading) | `World` SoA | built-in + named data components (#46) |
   | Identity | a component | tag / marker, indexed → queryable |
   | Per-entity-per-frame behavior | `systems.zig` | free-function systems over queries (native) |
   | Game rules (win/lose, spawn-on-eat) | `rules.lua` (one table) | event/timer handlers that query + mutate via commands |
   | Identity → handle | `mana` | `find` query accessor |

6. **Scripts are rules, not entity behavior** (diverging from Godot deliberately): one
   handler table per Sim (ADR 0003 §1), dispatched events/timers, no per-entity Lua.
   `on_scene_enter` (ADR 0017) is where a script *queries for its entities and wires
   timers/rules* — not where it spawns the world (the world is scene data).

## Consequences

- **The open scripting work reorganizes into one model** instead of ad-hoc gaps.
  Ordered by what Snake needs on top of this decision:
  1. **Scene→prototype instancing + entity tags + `mana.find`** (new — the data/identity
     foundation this ADR introduces; file as issues).
  2. `on_scene_enter` to query + wire (#54 / ADR 0017).
  3. Timers (#55), `set_position` (#56), input (#57), seeded RNG (#47), data
     components (#46) as games need them.
- **Snake becomes data-first:** `board.zon` declares the head, initial segments, and
  food as tagged prototype instances; `rules.lua`'s `on_scene_enter` does
  `head = mana.find("head")`, schedules the move timer, and drives handles it stored —
  no script-spawned initial world. Validated (on paper) against Tetris (a well + random
  first piece = scene data + one bootstrap random-spawn) and an RPG (player prototype
  with an inventory data component); those are lenses, not commitments.
- **Builds on, does not supersede,** ADR 0004 (scene schema — gains instancing) and
  ADR 0016 (prototypes — gain a tag); ADR 0017's `on_scene_enter` keeps its role,
  correctly scoped by this model.
- **Committed to:** entities stay flat (IDs + components); templates are flat bundles;
  rules are one script over events/queries; identity is tags.
- **Explicitly not doing** (no speculative flexibility — add only when a game needs it):
  entity **parenting/hierarchy** and multi-entity rigid prefabs (Godot-style nesting) —
  Snake's segments are independent entities; **per-entity scripts**; a full scene
  *transition/streaming* system (this defines instancing + the enter hook, not level
  switching); archetype storage (ADR 0001 already chose sparse sets); a general
  query-by-arbitrary-component language (tags cover the identity need; systems handle
  component intersections natively).
