-- games/snake/rules.lua — grid Snake, all logic in Lua (CLAUDE.md: Lua decides
-- *what*; the engine executes *how*). No src/ change is allowed for this package;
-- where the engine cannot yet express something, it is marked GAP and filed as an
-- issue rather than patched here.
--
-- The whole game is event- and timer-driven — never a per-frame per-entity Lua loop
-- (ADR 0003 forbids on_update). The snake advances one cell per timer tick; input
-- only changes the heading.

local W, H = 16, 16 -- board bounds in grid cells
local STEP = 0.15 -- seconds per move (grid tick)

-- Mutable game state. Seeded in `start` (see the on_start GAP below).
local dir = { x = 1, y = 0 } -- current heading (grid delta)
local pending = { x = 1, y = 0 } -- next heading, applied at the move boundary
local body = {} -- ordered body cells, head first: { {x,y,handle}, ... }
local food = { x = 0, y = 0, handle = nil }
local alive = false

local function occupied(x, y)
    for _, seg in ipairs(body) do
        if seg.x == x and seg.y == y then return true end
    end
    return false
end

local function place_food()
    -- GAP #47: mana.random_int(lo, hi) is not wired yet (needs a seeded Sim RNG).
    -- A grid game needs deterministic randomness from the sim's stream, not a
    -- scripted counter. Placeholder scan avoids overlapping the body.
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            if not occupied(x, y) then
                food.x, food.y = x, y
                if food.handle == nil then
                    food.handle = mana.spawn("food", x, y, 0)
                else
                    -- GAP: mana has no set_position/set_transform — only set_velocity.
                    -- Teleporting an entity to a grid cell is impossible today.
                    mana.set_position(food.handle, x, y, 0)
                end
                return
            end
        end
    end
end

local function grow(x, y)
    local h = mana.spawn("segment", x, y, 0)
    table.insert(body, 1, { x = x, y = y, handle = h })
end

-- One grid step: advance the head, drag the body, handle food and death.
local function step()
    if not alive then return end
    dir = pending
    local hx, hy = body[1].x + dir.x, body[1].y + dir.y

    -- Wall or self collision ⇒ death (reset the run).
    if hx < 0 or hy < 0 or hx >= W or hy >= H or occupied(hx, hy) then
        alive = false
        -- (reset/respawn logic would go here — omitted until the run loop exists)
        return
    end

    local eating = (hx == food.x and hy == food.y)

    -- Move each segment to the cell of the one ahead (teleport), tail first.
    for i = #body, 2, -1 do
        local ahead = body[i - 1]
        body[i].x, body[i].y = ahead.x, ahead.y
        mana.set_position(body[i].handle, ahead.x, ahead.y, 0) -- GAP: no set_position
    end
    body[1].x, body[1].y = hx, hy
    mana.set_position(body[1].handle, hx, hy, 0) -- GAP: no set_position

    if eating then
        grow(food.x, food.y) -- new head cell becomes a fresh segment
        place_food()
    end
end

-- Bootstrap: spawn the initial snake + food and start the move timer. Must run with
-- a live host (i.e. during a dispatch), which today only happens for the events
-- below — none of which fire at sim start. GAP: there is no on_start / on_load event.
local function start()
    local cx, cy = W // 2, H // 2
    body = {}
    grow(cx, cy) -- head
    dir, pending = { x = 1, y = 0 }, { x = 1, y = 0 }
    alive = true
    place_food()
    mana.every(STEP, step) -- GAP: timers (mana.every/after/cancel) are not wired to Lua
end

return {
    -- Bootstrap (ADR 0017): on_scene_enter fires once when the board loads, host-live,
    -- so start() can spawn the snake + food and schedule the move timer.
    on_scene_enter = function(ev)
        start()
    end,

    -- Directional input (ADR 0021): on_key fires on each key edge; turn on a press,
    -- and never reverse straight back onto the neck.
    on_key = function(ev)
        if not ev.pressed then return end
        if ev.key == "up" and dir.y == 0 then pending = { x = 0, y = -1 } end
        if ev.key == "down" and dir.y == 0 then pending = { x = 0, y = 1 } end
        if ev.key == "left" and dir.x == 0 then pending = { x = -1, y = 0 } end
        if ev.key == "right" and dir.x == 0 then pending = { x = 1, y = 0 } end
    end,
}
