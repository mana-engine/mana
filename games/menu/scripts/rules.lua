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

-- MIRRORS ../input.zon's SHIPPED defaults, which are the source of truth: these restate
-- them (the same content-authored-defaults-kept-in-sync convention `volume` keeps against
-- save/settings.zon) because a script cannot read that file (ADR 0003 §7 removed io/os).
-- They cover the actions the player has NOT rebound; for the ones they have, `bindings`
-- below is seeded by the engine from save/input.zon (ADR 0041 §4 amendment, #247) and
-- wins — see sources_of. Both mirrors are exposed on the handler table so
-- tests/menu_acceptance.zig can assert them against input.zon and catch drift.
--
-- EVERY shipped source must be mirrored, in BOTH vocabularies: an action there binds a
-- key AND a gamepad button, and the duplicate check below is only as complete as this
-- mirror. Mirroring keys alone silently accepts rebinding one action to another's pad
-- button — one press would then fire both actions.
local DEFAULT_KEYS = { fire = "w", interact = "a", pause = "s" }
local DEFAULT_PAD = { fire = "pad_west", interact = "pad_north", pause = "pad_start" }

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

    -- ADR 0041 §4's handler-table contract, TWO-WAY with the engine's persistence driver:
    -- `bindings` is action -> captured source string, the WHOLE player override (only the
    -- actions actually rebound; an absent action keeps its ../input.zon default), and
    -- `bindings_revision` is the "commit this" counter the driver polls.
    --
    -- The engine SEEDS `bindings` from save/input.zon at load and after each reload (ADR
    -- 0041 §4 amendment, #247), so it starts each session holding what is really
    -- persisted: that is what makes the whole-override write above safe across sessions
    -- (otherwise the first rebind of session 2 would drop session 1's), and what lets
    -- bound_elsewhere validate against LIVE bindings instead of the shipped mirror.
    -- Seeding never touches `bindings_revision` — only an accepted capture does, so
    -- nothing is written until the player actually rebinds something.
    bindings = {},
    bindings_revision = 0,

    -- The mirrors above, exposed for the drift assertion (both, or it cannot catch a
    -- pad default drifting out of sync — the exact hole that shipped a broken
    -- duplicate check the first time).
    default_bindings = DEFAULT_KEYS,
    default_pad_bindings = DEFAULT_PAD,

    capture_action = "",   -- "" = idle; else the action awaiting a press
    accepted_bindings = 0, -- accepted captures (UI echo / test observable)
    rejected_bindings = 0, -- reserved-or-duplicate captures, not recorded
}

local function clampi(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- Every source `action` currently fires on. A rebind REPLACES the action's whole
-- binding (per-action replace, ADR 0041 §2), collapsing it to that one captured source;
-- an action the player never rebound still fires on BOTH ../input.zon defaults — its
-- key and its gamepad button.
local function sources_of(action)
    local rebound = t.bindings[action]
    if rebound then return { rebound } end
    return { DEFAULT_KEYS[action], DEFAULT_PAD[action] }
end

-- Whether `source` already fires some action OTHER than `action` — in which case
-- accepting it would make one press fire both. Rebinding an action to an input it
-- already has is a no-op, not a conflict. Checks every source of every other action, so
-- a key capture is tested against keys and a pad capture against pad buttons (the two
-- vocabularies never collide: only pad sources carry the "pad_" prefix).
local function bound_elsewhere(action, source)
    for other, _ in pairs(DEFAULT_KEYS) do
        if other ~= action then
            for _, s in ipairs(sources_of(other)) do
                if s == source then return true end
            end
        end
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
