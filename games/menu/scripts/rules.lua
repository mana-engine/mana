-- games/menu/scripts/rules.lua — main menu + settings screen event handlers (issue
-- #135; ADR 0034 UI subsystem, ADR 0039 UI input events). Interaction is entirely
-- event-driven (on_focus/on_click/on_activate): no per-frame polling, no per-widget
-- script (CLAUDE.md: Lua decides *what*, the engine executes *how*).
--
-- Settings VALUES live here as plain Lua state (the same "local counter mirrored onto
-- the handler table" shape games/pacman/scripts/rules.lua already uses for score/
-- lives) — an engine-side driver reads them off the handler table after each
-- on_activate (the same `handlerFieldInt` seam ADR 0039's own tests use) and persists
-- them to save/settings.zon. The defaults below must match that file's shipped values.
--
-- `next_screen`/`quit_requested` are int sentinels (0 = no change) a driver polls
-- after dispatch to know when to swap the active `ui.Screen` or exit — the same
-- "engine reads Lua-declared intent via a plain field" idiom already established.

local VOLUME_MIN, VOLUME_MAX = 0, 10

local t = {
    volume = 7,      -- must match save/settings.zon's shipped default
    difficulty = 2,  -- 1 = easy, 2 = normal, 3 = hard
    next_screen = 0, -- 0 = none, 1 = main menu, 2 = settings
    quit_requested = 0,
    clicks = 0,
    focuses = 0,
}

local function clampi(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

t.on_click = function(ev)
    t.clicks = t.clicks + 1
end

t.on_focus = function(ev)
    t.focuses = t.focuses + 1
end

t.on_activate = function(ev)
    if ev.id == "start_button" then
        t.next_screen = 0 -- leaves the menu; a real runner would enter gameplay here
    elseif ev.id == "settings_button" then
        t.next_screen = 2
    elseif ev.id == "back_button" then
        t.next_screen = 1
    elseif ev.id == "quit_button" then
        t.quit_requested = 1
    elseif ev.id == "volume_up" then
        t.volume = clampi(t.volume + 1, VOLUME_MIN, VOLUME_MAX)
    elseif ev.id == "volume_down" then
        t.volume = clampi(t.volume - 1, VOLUME_MIN, VOLUME_MAX)
    elseif ev.id == "difficulty_cycle" then
        t.difficulty = (t.difficulty % 3) + 1
    end
end

return t
