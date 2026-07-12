-- games/snake/rules.lua — grid Snake, all logic in Lua (CLAUDE.md: Lua decides
-- *what*; the engine executes *how*). No src/ change is part of this package.
--
-- The whole game is event- and timer-driven — never a per-frame per-entity Lua loop
-- (ADR 0003 forbids on_update). The snake advances one cell per timer tick; input
-- only changes the heading. The board is centred on the world origin so it renders
-- centred on screen (there is no camera yet — that is a later engine feature).

local HALF = 8
local MIN, MAX = -HALF, HALF - 1 -- play-field cells [-8, 7] in x and y, around origin
local STEP = 0.15                -- seconds per move (grid tick)

local dir = { x = 1, y = 0 }     -- current heading (grid delta)
local pending = { x = 1, y = 0 } -- next heading, applied at the move boundary
local body = {}                  -- ordered cells, head first: { {x,y,handle}, ... }
local food = { x = 0, y = 0, handle = nil }
local rng = 1 -- content-side deterministic PRNG for food, until #47 wires a seeded Sim RNG

-- LCG → an integer in [0, n). Deterministic: math.random is removed from the sandbox
-- (ADR 0003 §7), so content that wants variety rolls its own until mana.random lands.
local function rand(n)
    rng = (rng * 1103515245 + 12345) % 2147483648
    return rng % n
end

-- Is (x, y) a body cell? `ignore_tail` skips the last segment, which vacates its cell
-- as the snake advances (so moving into it is legal — unless the snake is growing).
local function body_hits(x, y, ignore_tail)
    local last = #body
    if ignore_tail then last = last - 1 end
    for i = 1, last do
        if body[i].x == x and body[i].y == y then return true end
    end
    return false
end

-- Drop food on a pseudo-random free cell (never on the snake).
local function place_food()
    local span = MAX - MIN + 1
    for _ = 1, span * span do
        local x, y = MIN + rand(span), MIN + rand(span)
        if not body_hits(x, y, false) then
            food.x, food.y = x, y
            if food.handle == nil then
                food.handle = mana.spawn("food", x, y, 0)
            else
                mana.set_position(food.handle, x, y, 0)
            end
            return
        end
    end
end

-- Append a body segment at (x, y).
local function grow_at(x, y)
    table.insert(body, { x = x, y = y, handle = mana.spawn("segment", x, y, 0) })
end

-- The static wall ring one cell outside the play field — the boundary the snake dies
-- hitting. Spawned once (walls never move), so they persist across resets.
local function spawn_walls()
    for i = MIN - 1, MAX + 1 do
        mana.spawn("wall", i, MIN - 1, 0)
        mana.spawn("wall", i, MAX + 1, 0)
        mana.spawn("wall", MIN - 1, i, 0)
        mana.spawn("wall", MAX + 1, i, 0)
    end
end

-- (Re)start the run: clear any snake, spawn a fresh head at the centre, place food.
local function reset()
    for _, seg in ipairs(body) do mana.despawn(seg.handle) end
    body = {}
    grow_at(0, 0) -- head is body[1], at the world origin (screen centre)
    dir = { x = 1, y = 0 }
    pending = { x = 1, y = 0 }
    place_food()
end

-- One grid step: advance the head, drag the body, eat/grow, restart on collision.
local function step()
    dir = pending
    local hx, hy = body[1].x + dir.x, body[1].y + dir.y
    local eating = (hx == food.x and hy == food.y)

    -- Wall, or self (the tail cell is free this step unless we grow into it).
    if hx < MIN or hy < MIN or hx > MAX or hy > MAX or body_hits(hx, hy, not eating) then
        reset()
        return
    end

    -- Drag the body forward: each segment takes the cell of the one ahead, tail first.
    local vacated_x, vacated_y = body[#body].x, body[#body].y
    for i = #body, 2, -1 do
        body[i].x, body[i].y = body[i - 1].x, body[i - 1].y
        mana.set_position(body[i].handle, body[i].x, body[i].y, 0)
    end
    body[1].x, body[1].y = hx, hy
    mana.set_position(body[1].handle, hx, hy, 0)

    if eating then
        grow_at(vacated_x, vacated_y) -- extend into the cell the tail just left
        place_food()
    end
end

-- Turn, unless it is a 180° reversal of the *committed* heading. Checking `dir`, not
-- `pending`, is what stops a fast up-then-left (from a rightward snake) sneaking a
-- reversal through the intermediate turn: left is always a reversal of right,
-- whatever was queued between. One effective turn per step, never an about-face.
local function try_turn(nx, ny)
    if nx == -dir.x and ny == -dir.y then return end
    pending = { x = nx, y = ny }
end

return {
    -- Bootstrap (ADR 0017): fires once when the board loads, host-live.
    on_scene_enter = function(ev)
        spawn_walls()
        reset()
        mana.every(STEP, step) -- the move loop (ADR 0019)
    end,

    -- Directional input (ADR 0021): on a key press, turn. +y is up on screen.
    on_key = function(ev)
        if not ev.pressed then return end
        if ev.key == "up" then try_turn(0, 1) end
        if ev.key == "down" then try_turn(0, -1) end
        if ev.key == "left" then try_turn(-1, 0) end
        if ev.key == "right" then try_turn(1, 0) end
    end,
}
