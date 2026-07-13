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

-- Contact classification by data tag (kept in sync with prototypes.zon / maze.zon).
local KIND_PAC, KIND_GHOST, KIND_DOT, KIND_PELLET = 1, 2, 3, 4

local RETARGET = 0.1 -- seconds between target-selection passes (finer than a cell cross)
local MODE_SECS = 7.0 -- seconds between chase/scatter flips
local FRIGHT = 6.0    -- seconds a power pellet keeps ghosts frightened

-- Start cells and per-ghost scatter corners (walkable floor in the maze).
local PAC_START = { col = 8, row = 9 }
local GHOST_STARTS = { { 8, 5 }, { 9, 5 }, { 10, 5 } }
local SCATTER = { { 1, 1 }, { 17, 1 }, { 1, 9 } }

-- Mutable game state, seeded in on_scene_enter (host-live). Handles come from mana.spawn.
local pac = nil                    -- pac's entity handle
local pac_dir = { dc = -1, dr = 0 } -- current heading in cell deltas; default LEFT
local ghosts = {}                  -- { { handle, home = {col,row}, scatter = {col,row} }, ... }
local score = 0
local frightened = false
local mode = "chase"

-- Select a nav target cell for `handle` (ADR 0027 §3: selection is a plain data write;
-- the engine steers). No steering happens here.
local function set_target(handle, col, row)
    mana.set(handle, "nav_target_col", col)
    mana.set(handle, "nav_target_row", row)
end

-- Pac's current grid cell, from its live world position.
local function pac_cell()
    local x, y = mana.position(pac)
    return world_to_cell(x, y)
end

-- One selection pass (a coarse timer, a handful of movers — never a per-frame world
-- scan). Pac targets the far interior cell in its heading, so nav paths it steadily down
-- the corridor and turns when the heading changes; a wall straight ahead simply leaves
-- pac's shortest path bending with the corridor. Each ghost targets pac's cell (chase),
-- a corner (scatter), or its corner (frightened flee); the native BFS finds the path and
-- the next step. Interior cells are cols/rows [1, W-2]/[1, H-2] (the border is wall).
local function retarget()
    local pc, pr = pac_cell()
    set_target(pac, clampi(pc + pac_dir.dc * W, 1, W - 2), clampi(pr + pac_dir.dr * H, 1, H - 2))
    for _, g in ipairs(ghosts) do
        if frightened or mode == "scatter" then
            set_target(g.handle, g.scatter[1], g.scatter[2])
        else
            set_target(g.handle, pc, pr) -- chase pac's cell
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
-- window's close (ADR 0019 timer). Mode *timing* was never an engine gap.
local function begin_fright()
    frightened = true
    for _, g in ipairs(ghosts) do mana.set(g.handle, "frightened", 1) end
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

-- Pac caught by a non-frightened ghost: teleport back to the start cell (a run/lives
-- loop is out of scope for this scaffold).
local function reset_pac()
    local wx, wy = cell_to_world(PAC_START.col, PAC_START.row)
    mana.set_position(pac, wx, wy, 0)
    pac_dir = { dc = -1, dr = 0 }
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
            ghosts[i] = { handle = mana.spawn("ghost", gx, gy, 0), home = gc, scatter = SCATTER[i] }
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
        elseif other_kind == KIND_GHOST then
            if frightened then send_home(other) else reset_pac() end
        end
    end,

    -- Directional input (ADR 0021): a key press sets pac's heading; the next selection
    -- pass turns that into a nav target. +y (row+) is up on screen.
    on_key = function(ev)
        if not ev.pressed then return end
        if ev.key == "up" then pac_dir = { dc = 0, dr = 1 } end
        if ev.key == "down" then pac_dir = { dc = 0, dr = -1 } end
        if ev.key == "left" then pac_dir = { dc = -1, dr = 0 } end
        if ev.key == "right" then pac_dir = { dc = 1, dr = 0 } end
    end,
}
