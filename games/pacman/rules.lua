-- games/pacman/rules.lua — grid Pac-Man, all logic in Lua (CLAUDE.md: Lua decides
-- *what*; the engine executes *how*). No src/ change is part of this package; where
-- the engine cannot yet express something it is marked GAP and filed as an issue,
-- never patched here.
--
-- The whole game is event- and timer-driven — never a per-frame per-entity Lua loop
-- (ADR 0003 forbids on_update). Pac and the ghosts advance one cell per grid tick;
-- input only buffers the next turn. This is the same bootstrap → input → timer →
-- mutate loop Snake uses (on_scene_enter + on_key + mana.every + set_position), which
-- is exactly the point: reusing the engine fundamentals, not adding genre glue.
--
-- Status: DISCOVERY SCAFFOLD. This loads, spawns a maze, and moves pieces on the grid,
-- but it is NOT a finished Pac-Man — three engine fundamentals are missing (see the
-- GAP markers and games/pacman/README.md): tile/maze *data*, native ghost
-- pathfinding/steering, and content-declarable colliders (native collision).

local STEP = 0.15 -- seconds per grid move (the tick cadence; ADR 0019)
local FRIGHT = 6.0 -- seconds a power pellet keeps ghosts frightened

-- The maze, authored as an ASCII grid. '#' wall, '.' dot, 'o' power pellet, 'P' pac
-- start, 'g' ghost start, ' ' empty. Rows are top-to-bottom; +y is up on screen.
--
-- GAP (tile/maze level data): this layout *should* be scene data the engine reads —
-- walls the native collision system consumes and the renderer draws as tiles — but no
-- tile/level data model exists (ADR 0004 scenes are flat inline entity lists; there is
-- no grid/tilemap concept). So the maze lives here as content the script interprets,
-- and every wall/dot below is spawned as an individual entity. Filed as a gap issue.
local MAZE = {
    "###################",
    "#........#........#",
    "#.####.#.#.#.####.#",
    "#.................#",
    "#.##.###.#.###.##.#",
    "#....#..ggg..#....#",
    "#.##.#.#####.#.##.#",
    "#........#........#",
    "#.##.###.#.###.##.#",
    "#o......P........o#",
    "###################",
}
local W, H = 19, 11 -- maze dimensions; grid is centred on the world origin

-- Grid cell → world coordinates. Column/row are 1-indexed into MAZE; the maze is
-- centred on (0, 0) and the row axis is flipped so the first row is the top (+y).
local function world_x(col) return (col - 1) - (W - 1) / 2 end
local function world_y(row) return (H - 1) / 2 - (row - 1) end

-- Mutable game state, seeded in build_maze (on_scene_enter, host-live).
local walls = {}        -- cell key → true (static maze geometry)
local dots = {}         -- cell key → dot entity handle (pips still uneaten)
local pellets = {}      -- cell key → power-pellet handle
local pac = nil         -- { x, y, handle, dir, pending, start_x, start_y }
local ghosts = {}       -- { { x, y, handle, dir, home_x, home_y }, ... }
local score = 0
local frightened = false

local UP, DOWN = { x = 0, y = 1 }, { x = 0, y = -1 }
local LEFT, RIGHT = { x = -1, y = 0 }, { x = 1, y = 0 }

local function key(x, y) return x .. "," .. y end
local function is_wall(x, y) return walls[key(x, y)] == true end
local function reverse(d) return { x = -d.x, y = -d.y } end

-- Spawn every maze cell as an entity and record the player + ghost starts. Walls,
-- dots, and pellets are individual entities because there is no tile data the engine
-- draws or collides directly (see the GAP above).
local function build_maze()
    for row = 1, H do
        local line = MAZE[row]
        for col = 1, W do
            local ch = line:sub(col, col)
            local x, y = world_x(col), world_y(row)
            if ch == "#" then
                walls[key(x, y)] = true
                mana.spawn("wall", x, y, 0)
            elseif ch == "." then
                dots[key(x, y)] = mana.spawn("dot", x, y, 0)
            elseif ch == "o" then
                pellets[key(x, y)] = mana.spawn("pellet", x, y, 0)
            elseif ch == "P" then
                pac = {
                    x = x,
                    y = y,
                    handle = mana.spawn("pac", x, y, 0),
                    dir = LEFT,
                    pending = LEFT,
                    start_x = x,
                    start_y = y,
                }
            elseif ch == "g" then
                table.insert(ghosts, {
                    x = x,
                    y = y,
                    handle = mana.spawn("ghost", x, y, 0),
                    dir = UP,
                    home_x = x,
                    home_y = y,
                })
            end
        end
    end
end

-- Eat whatever is under Pac after a move: a dot scores 10, a power pellet scores 50
-- and opens the frightened window. Score is mirrored to Pac's `score` data component
-- (ADR 0024) so the engine — a future HUD/overlay — can read it without the script.
local function eat_at(x, y)
    local k = key(x, y)
    if dots[k] then
        mana.despawn(dots[k])
        dots[k] = nil
        score = score + 10
        mana.set(pac.handle, "score", score)
    elseif pellets[k] then
        mana.despawn(pellets[k])
        pellets[k] = nil
        score = score + 50
        mana.set(pac.handle, "score", score)
        frightened = true
        for _, g in ipairs(ghosts) do mana.set(g.handle, "frightened", 1) end
        -- Mode timer (ADR 0019): end the frightened window after FRIGHT seconds. This
        -- pattern — a scripted window over per-entity data — is fully expressible today
        -- (mana.after + mana.set), so chase/scatter/frightened *timing* is NOT a gap.
        mana.after(FRIGHT, function()
            frightened = false
            for _, g in ipairs(ghosts) do mana.set(g.handle, "frightened", 0) end
        end)
    end
end

-- Send a ghost back to its pen (on being eaten while frightened).
local function send_home(g)
    g.x, g.y = g.home_x, g.home_y
    g.dir = UP
    mana.set_position(g.handle, g.x, g.y, 0)
end

-- Advance Pac one cell: commit the buffered turn if that way is open, then step if the
-- committed heading is open (otherwise stop at the wall).
--
-- GAP (native collision / content colliders): pac-vs-wall here is a Lua table lookup
-- (`is_wall`) because a content package cannot declare a Collider on a spawned entity —
-- the Bundle/EntityDef schema carries transform/velocity/health/data but no collider,
-- so the engine's native collision system and its `on_collision_begin` event are
-- unreachable from ZON/Lua. A grid game re-deriving overlap in Lua duplicates a native
-- system. Filed as a gap issue.
local function step_pac()
    if not is_wall(pac.x + pac.pending.x, pac.y + pac.pending.y) then
        pac.dir = pac.pending
    end
    local nx, ny = pac.x + pac.dir.x, pac.y + pac.dir.y
    if not is_wall(nx, ny) then
        pac.x, pac.y = nx, ny
        mana.set_position(pac.handle, nx, ny, 0)
        eat_at(nx, ny)
    end
end

-- Advance one ghost one cell. GAP (native pathfinding / steering): a real ghost chases
-- Pac (or scatters to a corner) along the maze — that is grid pathfinding + steering,
-- which CLAUDE.md says is NATIVE engine work (Lua only *selects* the target tile). The
-- engine has no pathfinding/steering port, so this is a placeholder: pick a random
-- legal, non-reversing direction at each cell (seeded via mana.random_int, ADR 0022, so
-- runs stay deterministic). This is the biggest gap; filed as its own issue.
local function step_ghost(g)
    local options = {}
    for _, d in ipairs({ UP, DOWN, LEFT, RIGHT }) do
        local rev = (d.x == -g.dir.x and d.y == -g.dir.y)
        if not rev and not is_wall(g.x + d.x, g.y + d.y) then
            table.insert(options, d)
        end
    end
    if #options == 0 then options = { reverse(g.dir) } end -- dead end: turn around
    g.dir = options[mana.random_int(1, #options)]
    g.x, g.y = g.x + g.dir.x, g.y + g.dir.y
    mana.set_position(g.handle, g.x, g.y, 0)
end

-- Resolve a Pac/ghost meeting: frightened ghost goes home, otherwise Pac dies back to
-- its start cell. (A run/score/life loop is out of scope for this scaffold.)
local function resolve_contacts()
    for _, g in ipairs(ghosts) do
        if g.x == pac.x and g.y == pac.y then
            if frightened then
                send_home(g)
            else
                pac.x, pac.y = pac.start_x, pac.start_y
                pac.dir, pac.pending = LEFT, LEFT
                mana.set_position(pac.handle, pac.x, pac.y, 0)
            end
        end
    end
end

-- One grid tick: move Pac, move each ghost, then resolve any overlap. A handful of
-- entities on a timer — never a per-frame scan of the whole world.
local function step()
    step_pac()
    for _, g in ipairs(ghosts) do step_ghost(g) end
    resolve_contacts()
end

-- Buffer a turn; the move timer applies it at the next open cell. +y is up on screen.
local function turn(nx, ny)
    if pac then pac.pending = { x = nx, y = ny } end
end

return {
    -- Bootstrap (ADR 0017): fires once when the maze loads, host-live — spawn the maze
    -- and start the move loop (ADR 0019).
    on_scene_enter = function(ev)
        build_maze()
        mana.every(STEP, step)
    end,

    -- Directional input (ADR 0021): on a key press, buffer the turn.
    on_key = function(ev)
        if not ev.pressed then return end
        if ev.key == "up" then turn(0, 1) end
        if ev.key == "down" then turn(0, -1) end
        if ev.key == "left" then turn(-1, 0) end
        if ev.key == "right" then turn(1, 0) end
    end,
}
