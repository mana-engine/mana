-- games/snake/rules.lua — grid Snake, all logic in Lua (CLAUDE.md: Lua decides
-- *what*; the engine executes *how*). No src/ change is part of this package.
--
-- The whole game is event- and timer-driven — never a per-frame per-entity Lua loop
-- (ADR 0003 forbids on_update). The snake advances one cell per timer tick; input
-- only changes the heading.

local W, H = 16, 16 -- board bounds in grid cells
local STEP = 0.15   -- seconds per move (grid tick)

-- Mutable game state, (re)seeded by `reset`.
local dir = { x = 1, y = 0 }     -- current heading (grid delta)
local pending = { x = 1, y = 0 } -- next heading, applied at the move boundary
local body = {}                  -- ordered cells, head first: { {x,y,handle}, ... }
local food = { x = 0, y = 0, handle = nil }

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

local function place_food()
    -- #47 (deferred): a seeded Sim RNG would place food randomly; until then a scan
    -- for the first free cell keeps it deterministic and off the snake.
    for y = 0, H - 1 do
        for x = 0, W - 1 do
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
end

-- Append a body segment at (x, y).
local function grow_at(x, y)
    table.insert(body, { x = x, y = y, handle = mana.spawn("segment", x, y, 0) })
end

-- (Re)start the run: clear any snake, spawn a fresh head at the centre, place food.
local function reset()
    for _, seg in ipairs(body) do mana.despawn(seg.handle) end
    body = {}
    grow_at(W // 2, H // 2) -- head is body[1]
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
    if hx < 0 or hy < 0 or hx >= W or hy >= H or body_hits(hx, hy, not eating) then
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

-- Turn, unless it reverses the last intended heading straight onto the neck (only a
-- snake with a body can reverse into itself; a lone head may turn freely).
local function try_turn(nx, ny)
    if #body > 1 and nx == -pending.x and ny == -pending.y then return end
    pending = { x = nx, y = ny }
end

return {
    -- Bootstrap (ADR 0017): fires once when the board loads, host-live.
    on_scene_enter = function(ev)
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
