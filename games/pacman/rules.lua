-- games/pacman/rules.lua — grid Pac-Man, built on the engine fundamentals (CLAUDE.md:
-- Lua decides *what*; the engine executes *how*). No src/ change is part of this
-- package. This is the migration off the discovery scaffold: the maze, pathfinding,
-- and overlap math that used to live here in Lua are now engine features —
--
--   * the maze is scene data (ADR 0026 tilemap: walls → static nav-blocking colliders),
--     see scenes/maze.zon — no ASCII grid or per-cell spawn loop in Lua anymore;
--   * ghost (and pac) movement is native pathfinding + steering (ADR 0027): Lua only
--     SELECTS a target cell via `mana.set` on the `nav_target_col`/`nav_target_row` data
--     components; the engine's `nav` system BFS-paths and steers every tick. There is no
--     pathfinder and no per-entity-per-frame loop in Lua;
--   * pac-eats-dot / pac-vs-ghost are `on_collision_begin` events off native colliders
--     (ADR 0025), classified by a `kind` data tag — not Lua coordinate math.
--
-- What stayed (never a gap): mode timing via `mana.every`/`mana.after`, per-entity data
-- (`score`/`frightened`, ADR 0024), and the input→heading path (`on_key`) Snake proved.

-- Grid frame — must match scenes/maze.zon's tilemap (origin/cell_size). Cell (col,row)
-- maps to world (col-9, row-5, 0); world maps back by rounding to the nearest cell.
local ORIGIN_X, ORIGIN_Y, CELL = -9, -5, 1
local W, H = 19, 11

local function cell_to_world(col, row)
    return ORIGIN_X + col * CELL, ORIGIN_Y + row * CELL
end
local function world_to_cell(wx, wy)
    return math.floor((wx - ORIGIN_X) / CELL + 0.5), math.floor((wy - ORIGIN_Y) / CELL + 0.5)
end
local function clampi(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- The farthest still-walkable cell reached by stepping (dc,dr) from (col,row) until the
-- cell before the first wall — pac's straight-run nav target. Walkability is a live
-- read of the engine's maze grid (`mana.is_walkable`, ADR 0035, issue #143) — the SAME
-- tilemap `nav`'s native BFS (ADR 0027) paths over — never a Lua-side copy of
-- scenes/maze.zon, so there is nothing here that can drift out of sync with the maze.
-- A pure-axis target (same row for a horizontal heading, same col for a vertical one)
-- has a *unique* shortest path — the straight line — because any deviation adds
-- perpendicular steps, so the native BFS never shortcuts a corner even across an open
-- room; pac holds one lane until it hits a wall or the player turns. If the next cell is
-- already a wall this returns (col,row) itself, so pac's target is its own cell and nav
-- stops it flush.
local function farthest_open(col, row, dc, dr)
    local c, r = col, row
    while mana.is_walkable(c + dc, r + dr) do
        c, r = c + dc, r + dr
    end
    return c, r
end

-- Contact classification by data tag (kept in sync with prototypes.zon / maze.zon).
local KIND_PAC, KIND_GHOST, KIND_DOT, KIND_PELLET, KIND_FRUIT = 1, 2, 3, 4, 5

local RETARGET = 0.1 -- seconds between target-selection passes (finer than a cell cross)
local MODE_SECS = 7.0 -- seconds between chase/scatter flips
local FRIGHT = 6.0    -- seconds a power pellet keeps ghosts frightened
-- Issue #128 (tint/blink cues, subsumes #106's frightened-blue): `frightened` widens
-- from a 0/1 flag to 0/1/2 — the ghost `tint_cue` (prototypes.zon) reads the SAME data
-- component `retarget` already checks, so no new per-entity state and no new `mana`
-- API. BLINK_LEAD is how long before the window closes the ghosts flip 1 -> 2 (solid
-- blue -> blinking blue/white), the classic "frightened is about to end" warning.
local BLINK_LEAD = 2.0
local FLASH_SECS = 0.4 -- how long pac's fruit-eaten tint cue (`flash`) holds before reverting

-- Start cells and per-ghost scatter corners (walkable floor in the maze) — the four
-- interior corners of the playable grid (cols/rows [1, W-2]/[1, H-2]).
local PAC_START = { col = 8, row = 9 }
local GHOST_STARTS = { { 8, 5 }, { 9, 5 }, { 10, 5 }, { 11, 5 } }
local SCATTER = { { 1, 1 }, { 17, 1 }, { 1, 9 }, { 17, 9 } }
-- Four named ghost prototypes (ADR 0030): appearance color only — the classic
-- Blinky(red)/Pinky(pink)/Inky(cyan)/Clyde(orange) *behaviors* are selected by spawn
-- index in `retarget` below (Refs #62), never carried by the prototype itself.
local GHOST_PROTOTYPES = { "ghost_red", "ghost_pink", "ghost_cyan", "ghost_orange" }
-- Ghost spawn indices, named for readability at every call site below.
local BLINKY, PINKY, INKY, CLYDE = 1, 2, 3, 4
-- Pinky ambushes the cell this many cells ahead of pac's heading; Inky's vector is
-- doubled through the cell two ahead (the classic arcade constants). Clyde chases
-- while farther than this many cells (Euclidean, squared to skip a sqrt) from pac,
-- else retreats to his scatter corner — he never gets close enough to trap pac.
local PINKY_AHEAD = 4
local INKY_AHEAD = 2
local CLYDE_CHASE_DIST_SQ = 8 * 8

-- Mutable game state, seeded in on_scene_enter (host-live). Handles come from mana.spawn.
local pac = nil                    -- pac's entity handle
local pac_dir = { dc = -1, dr = 0 } -- current heading in cell deltas; default LEFT
local ghosts = {}                  -- { { handle, home = {col,row}, scatter = {col,row} }, ... }
local score = 0
local START_LIVES = 3
local lives = START_LIVES          -- remaining lives; the HUD reads pac's `lives` data component
local frightened = false
local mode = "chase"

-- Select a nav target cell for `handle` (ADR 0027 §3: selection is a plain data write;
-- the engine steers). No steering happens here.
local function set_target(handle, col, row)
    mana.set(handle, "nav_target_col", col)
    mana.set(handle, "nav_target_row", row)
end

-- An entity's current grid cell, from its live world position (pac or a ghost — nav
-- agents are all `Transform`-bearing, so this generalizes `pac_cell`'s old body).
local function entity_cell(handle)
    local x, y = mana.position(handle)
    return world_to_cell(x, y)
end

local function pac_cell()
    return entity_cell(pac)
end

-- One selection pass (a coarse timer, a handful of movers — never a per-frame world
-- scan). Pac targets the FARTHEST walkable cell along its heading (#139), not the single
-- next cell (#108's original fix): a one-cell-ahead target let pac *reach* its target
-- before the next 0.1s retarget pass, so `start == target` → `nav.nextStep` returns null
-- → pac stopped flush and held until the next pass — a per-cell stall the player felt as
-- a stutter (ghosts, whose targets are always cells away, never stalled: same nav, so
-- steering was never the bug). A pure-axis far target down the current lane still keeps
-- classic Pac-Man's three rules — the BFS never shortcuts around a corner because a
-- same-row/same-col target's shortest path IS the straight line (`farthest_open`), so:
-- pac holds ONE straight lane at full speed, turns only when the player presses a new
-- heading (the next pass scans THAT direction), and glides to a flush stop at the wall
-- dead ahead (target = last walkable cell → pac reaches its centre and holds). In scatter
-- (or while any ghost is frightened) every ghost retreats to its own corner; the native
-- BFS finds the path and the next step. Interior cells are cols/rows [1, W-2]/[1, H-2]
-- (the border is wall).
--
-- In chase mode each ghost gets the classic arcade AI's distinct target, using only the
-- surface already available to Lua (ADR 0027 §3: selection, never steering, and no new
-- `mana` API) — `pac_dir`, the heading `on_key` already tracks, stands in for "pac's
-- facing direction":
--   * Blinky (index 1): pac's own cell — a direct chase.
--   * Pinky (index 2): the cell `PINKY_AHEAD` cells ahead of pac's heading — an ambush.
--   * Inky (index 3): the cell two ahead of pac, mirrored through Blinky's cell and
--     doubled — Blinky's position bends Inky's approach around a corner.
--   * Clyde (index 4): chases like Blinky while farther than `CLYDE_CHASE_DIST_SQ` from
--     pac; inside that radius he flees to his own scatter corner instead, so he never
--     closes the final few cells.
local function retarget()
    local pc, pr = pac_cell()
    set_target(pac, farthest_open(pc, pr, pac_dir.dc, pac_dir.dr))

    if frightened or mode == "scatter" then
        for _, g in ipairs(ghosts) do set_target(g.handle, g.scatter[1], g.scatter[2]) end
        return
    end

    local bc, br = entity_cell(ghosts[BLINKY].handle)
    for i, g in ipairs(ghosts) do
        if i == BLINKY then
            set_target(g.handle, pc, pr)
        elseif i == PINKY then
            set_target(g.handle,
                clampi(pc + pac_dir.dc * PINKY_AHEAD, 1, W - 2),
                clampi(pr + pac_dir.dr * PINKY_AHEAD, 1, H - 2))
        elseif i == INKY then
            local ac, ar = pc + pac_dir.dc * INKY_AHEAD, pr + pac_dir.dr * INKY_AHEAD
            set_target(g.handle,
                clampi(bc + 2 * (ac - bc), 1, W - 2),
                clampi(br + 2 * (ar - br), 1, H - 2))
        elseif i == CLYDE then
            local gc, gr = entity_cell(g.handle)
            local dc, dr = pc - gc, pr - gr
            if dc * dc + dr * dr > CLYDE_CHASE_DIST_SQ then
                set_target(g.handle, pc, pr)
            else
                set_target(g.handle, g.scatter[1], g.scatter[2])
            end
        end
    end
end

-- Flip chase/scatter (frightened overrides both while its window is open).
local function toggle_mode()
    mode = (mode == "chase") and "scatter" or "chase"
end

-- Add to the score and mirror it to pac's `score` data component so the engine (a HUD/
-- overlay) can read it without the script.
local function add_score(n)
    score = score + n
    mana.set(pac, "score", score)
end

-- Open the frightened window on eating a power pellet: flag every ghost and schedule the
-- window's close (ADR 0019 timer). Mode *timing* was never an engine gap. Two timers:
-- BLINK_LEAD seconds before the close, flip every STILL-frightened ghost from 1 (solid
-- blue) to 2 (blinking blue/white, issue #128) — the `if == 1` guard means a ghost
-- already caught and sent home (its flag cleared to 0 by `send_home`) is left alone, not
-- resurrected into the blink state.
local function begin_fright()
    frightened = true
    for _, g in ipairs(ghosts) do mana.set(g.handle, "frightened", 1) end
    mana.after(FRIGHT - BLINK_LEAD, function()
        for _, g in ipairs(ghosts) do
            if mana.get(g.handle, "frightened") == 1 then mana.set(g.handle, "frightened", 2) end
        end
    end)
    mana.after(FRIGHT, function()
        frightened = false
        for _, g in ipairs(ghosts) do mana.set(g.handle, "frightened", 0) end
    end)
end

-- Send an eaten (frightened) ghost back to its pen and clear its frightened flag.
local function send_home(handle)
    for _, g in ipairs(ghosts) do
        if g.handle == handle then
            local wx, wy = cell_to_world(g.home[1], g.home[2])
            mana.set_position(handle, wx, wy, 0)
            mana.set(handle, "frightened", 0)
            return
        end
    end
end

-- Pac caught by a non-frightened ghost: lose a life and restart the round. Teleport pac
-- back to its start cell AND return every ghost to its pen, so the actors are re-separated
-- instead of the pack staying piled on pac's death cell and immediately re-catching it
-- (the classic "reset the level on a death"). Lives (issue #133) tick down to 0 then loop
-- back to a full set — a run/game-over flow is a later slice; the point here is a live,
-- HUD-visible `lives` count driven off the SAME collision event, no new `mana` API. Nav
-- has no ghost-vs-ghost avoidance yet (ADR 0027 follow-up), so resetting the ghosts is
-- what actually breaks up the corner-mob.
local function reset_actors()
    lives = lives - 1
    if lives <= 0 then lives = START_LIVES end
    mana.set(pac, "lives", lives)
    local wx, wy = cell_to_world(PAC_START.col, PAC_START.row)
    mana.set_position(pac, wx, wy, 0)
    mana.set(pac, "flash", 0)
    pac_dir = { dc = -1, dr = 0 }
    for _, g in ipairs(ghosts) do
        local gx, gy = cell_to_world(g.home[1], g.home[2])
        mana.set_position(g.handle, gx, gy, 0)
        mana.set(g.handle, "frightened", 0)
    end
end

return {
    -- Bootstrap (ADR 0017): fires once when the maze loads, host-live. Walls and pickups
    -- are already in the world (materialized from the scene data); here we spawn the
    -- movers — the only pieces that need a Lua handle — and start the selection timers.
    -- Targets are chosen by the timer, not inline: a mover's nav_target_* columns only
    -- register at the flush after this spawn, so the first selection must run a tick later.
    on_scene_enter = function(ev)
        local px, py = cell_to_world(PAC_START.col, PAC_START.row)
        pac = mana.spawn("pac", px, py, 0)
        for i, gc in ipairs(GHOST_STARTS) do
            local gx, gy = cell_to_world(gc[1], gc[2])
            ghosts[i] = { handle = mana.spawn(GHOST_PROTOTYPES[i], gx, gy, 0), home = gc, scatter = SCATTER[i] }
        end
        mana.every(RETARGET, retarget)  -- selection (native nav does the steering)
        mana.every(MODE_SECS, toggle_mode)
    end,

    -- Native collision (ADR 0025/0008): pac meeting a dot/pellet/ghost. The engine reports
    -- each pair once (self, ev.other); we classify by the `kind` data tag, never geometry.
    on_collision_begin = function(self, ev)
        local ks, ko = mana.get(self, "kind"), mana.get(ev.other, "kind")
        if ks == nil or ko == nil then return end -- a piece already despawned this tick
        local other, other_kind
        if ks == KIND_PAC then
            other, other_kind = ev.other, ko
        elseif ko == KIND_PAC then
            other, other_kind = self, ks
        else
            return -- no pac in this pair (layers make this rare); nothing to resolve
        end
        if other_kind == KIND_DOT then
            mana.despawn(other)
            add_score(10)
        elseif other_kind == KIND_PELLET then
            mana.despawn(other)
            add_score(50)
            begin_fright()
        elseif other_kind == KIND_FRUIT then
            -- A player-facing cue with no gameplay effect beyond score (issue #128):
            -- flash pac's tint cue on, then off a beat later (ADR 0019 timer, no new
            -- `mana` API) — the same `flash` data component `pac`'s `tint_cue` reads.
            mana.despawn(other)
            add_score(100)
            mana.set(pac, "flash", 1)
            mana.after(FLASH_SECS, function() mana.set(pac, "flash", 0) end)
        elseif other_kind == KIND_GHOST then
            if frightened then send_home(other) else reset_actors() end
        end
    end,

    -- Directional input (ADR 0021): a key press sets pac's heading; the next selection
    -- pass turns that into a nav target. Issue #159: `cell_to_world` puts row+ at
    -- higher world y, and post-#155 (the live Vulkan vertical-flip fix) higher world y
    -- renders LOWER on screen, so row- (toward row 0, the top of the maze's ASCII art)
    -- is up on screen, not row+.
    on_key = function(ev)
        if not ev.pressed then return end
        if ev.key == "up" then pac_dir = { dc = 0, dr = -1 } end
        if ev.key == "down" then pac_dir = { dc = 0, dr = 1 } end
        if ev.key == "left" then pac_dir = { dc = -1, dr = 0 } end
        if ev.key == "right" then pac_dir = { dc = 1, dr = 0 } end
    end,
}
