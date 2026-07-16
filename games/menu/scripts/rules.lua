-- games/menu/scripts/rules.lua — main menu + settings + controls screen event handlers
-- (issues #135/#239; ADR 0034 UI subsystem, ADR 0039 UI input events, ADR 0041 in-game
-- remap). Interaction is entirely event-driven (on_focus/on_click/on_activate/
-- on_input_captured): no per-frame polling, no per-widget script (CLAUDE.md: Lua
-- decides *what*, the engine executes *how*).
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
--
-- REMAP (ADR 0041 §5, issue #239): the same idiom carries the controls screen. A
-- rebind row's on_activate arms `mana.capture_input(action)`; the engine intercepts the
-- next physical press edge and delivers `on_input_captured{action, source}`; this
-- script validates it and, on accept, records it in `bindings` and bumps
-- `bindings_revision` — the two handler fields the engine's persistence driver reads
-- (`src/engine/input_override.zig`) to write `save/input.zon`, which the watcher then
-- re-merges over `input.zon` and swaps live. Persist and apply are one motion: without
-- the revision bump nothing is written, and without the write nothing applies.
--
-- The script never touches a file (ADR 0003 §7 removed io/os) and never binds anything
-- itself: it proposes data, the engine owns the file (invariant #1).

local VOLUME_MIN, VOLUME_MAX = 0, 10

-- MIRRORS ../input.zon, which is the source of truth: `default_bindings` restates its
-- shipped binding per action (the same content-authored-defaults-kept-in-sync
-- convention `volume` keeps against save/settings.zon), because a script cannot read
-- either file and no engine seam hands it the loaded map. Exposed on the handler table
-- so tests/menu_acceptance.zig can assert the mirror against input.zon and catch drift.
-- Only ONE source per action here: capture yields one source, and an accepted rebind
-- REPLACES the action's whole binding (per-action replace, ADR 0041 §2), so a rebound
-- action loses its pad default — see games/menu/README.md.
local DEFAULT_BINDINGS = { fire = "w", interact = "a", pause = "s" }

-- The keys this menu's own UI layer claims (src/ui/focus.zig: arrows nav, enter/space
-- activate) plus escape as back/cancel. Binding an action to one would leave the
-- controls screen unusable, so a captured reserved key is rejected — and pressing
-- escape is how a player backs out of an armed capture without binding.
local RESERVED_SOURCES = {
    up = true, down = true, left = true, right = true,
    enter = true, space = true, escape = true,
}

-- Rebind row id -> the ../input.zon action it rebinds (screens/controls.zon).
local REBIND_ROWS = { rebind_fire = "fire", rebind_interact = "interact", rebind_pause = "pause" }

local t = {
    volume = 7,      -- must match save/settings.zon's shipped default
    difficulty = 2,  -- 1 = easy, 2 = normal, 3 = hard
    next_screen = 0, -- 0 = none, 1 = main menu, 2 = settings, 3 = controls
    quit_requested = 0,
    clicks = 0,
    focuses = 0,

    -- ADR 0041 §4's handler-table contract, read by the engine's persistence driver:
    -- `bindings` is action -> captured source string, the WHOLE player override (only
    -- the actions actually rebound; an absent action keeps its ../input.zon default),
    -- and `bindings_revision` is the "commit this" counter the driver polls.
    bindings = {},
    bindings_revision = 0,

    default_bindings = DEFAULT_BINDINGS, -- the mirror above, for the drift assertion
    capture_action = "",                 -- "" = idle; else the action awaiting a press
    accepted_bindings = 0,               -- accepted captures (UI echo / test observable)
    rejected_bindings = 0,               -- reserved-or-duplicate captures, not recorded
}

local function clampi(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- The binding `action` currently resolves to: the player's rebind if there is one, else
-- the ../input.zon default this file mirrors.
local function binding_of(action)
    return t.bindings[action] or DEFAULT_BINDINGS[action]
end

-- Whether `source` is already bound to some action OTHER than `action` — rebinding an
-- action to the input it already has is a no-op, not a conflict.
local function bound_elsewhere(action, source)
    for other, _ in pairs(DEFAULT_BINDINGS) do
        if other ~= action and binding_of(other) == source then return true end
    end
    return false
end

t.on_click = function(ev)
    t.clicks = t.clicks + 1
    -- A pointer press still reaches the UI while capture is armed — capture claims key
    -- and pad-button edges only (ADR 0041 §1) — so clicking away IS the pointer-side
    -- "never mind", and it must disarm or the next keypress would bind.
    if t.capture_action ~= "" then
        mana.cancel_capture()
        t.capture_action = ""
    end
end

t.on_focus = function(ev)
    t.focuses = t.focuses + 1
end

t.on_activate = function(ev)
    local rebind = REBIND_ROWS[ev.id]
    if rebind then
        -- Arm the engine's capture mode: the next physical press edge — whatever it is
        -- — comes back as on_input_captured instead of driving nav/activate/gameplay.
        t.capture_action = rebind
        mana.capture_input(rebind)
        return
    end
    if ev.id == "start_button" then
        t.next_screen = 0 -- leaves the menu; a real runner would enter gameplay here
    elseif ev.id == "settings_button" then
        t.next_screen = 2
    elseif ev.id == "controls_button" then
        t.next_screen = 3
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

-- The capture delivery (ADR 0041 §1): `ev.source` is the neutral binding descriptor the
-- engine names the pressed input with — a bare key name ("w"), or a "pad_"-prefixed
-- gamepad button ("pad_south"). Pass it through VERBATIM: the persistence driver owns
-- the translation into input.zon's `keys`/`pad_buttons` fields, so pre-stripping the
-- prefix here would silently produce a key binding for a button press.
--
-- Delivery already disarmed the engine's capture mode (it is one-shot), so this handler
-- only decides accept-or-not; there is nothing left to cancel on the accept path.
t.on_input_captured = function(ev)
    t.capture_action = ""
    if RESERVED_SOURCES[ev.source] or bound_elsewhere(ev.action, ev.source) then
        -- Escape (and any other UI-claimed key) reads as "never mind"; a duplicate would
        -- make two actions fire on one press. Neither is recorded, so no revision bump
        -- happens and the driver writes nothing — the file keeps its last good contents.
        mana.cancel_capture() -- idempotent: already disarmed above, explicit for the cancel path
        t.rejected_bindings = t.rejected_bindings + 1
        return
    end
    t.bindings[ev.action] = ev.source
    t.accepted_bindings = t.accepted_bindings + 1
    t.bindings_revision = t.bindings_revision + 1 -- the driver's "commit this" signal
end

-- This package has no gameplay; `on_action` exists so a fired action is OBSERVABLE —
-- it is what proves a rebind actually took effect (the newly bound input fires the
-- action, the old one no longer does) once the reloaded override swaps the live map.
-- Counting per action keeps it generic: no action name is spelled out here.
t.on_action = function(ev)
    if not ev.pressed then return end
    local field = "fired_" .. ev.action
    t[field] = (t[field] or 0) + 1
end

return t
