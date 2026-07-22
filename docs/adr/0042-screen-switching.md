# 0042. Screen switching: a globbed `screens/` set, a named screen request, one active screen

- Status: proposed
- Date: 2026-07-16

## Context

Issue #249 reads as a wiring bug: `games/menu/scripts/rules.lua` sets `next_screen = 2`
when the player activates SETTINGS, and nothing in the runner reacts, so the settings
and controls screens are unreachable in a real `--play` session. The claim checks out —
the only `setScreen` call in the runner is `src/runtime/main.zig:1058-1060`, inside
`playLoop`, and it hands `sim.ui_input` the package's `hud` screen and never revisits
the decision.

But it is **not** a wiring bug, because there is nothing to wire *to*. Three ADRs each
deferred the mechanism, and it fell through the gap between them:

- **ADR 0039 §6** (out of scope): *"No modal/overlay stacking (multiple simultaneously
  active screens racing for focus) — today's model is 'the one active screen' … a stack
  is a later, concretely-motivated design."* Its Context (`:38-39`) likewise defers
  *"multi-screen/modal stacking to a later, concretely-motivated ADR."*
- **ADR 0041 §7** (explicitly deferred): *"multi-screen switching from `on_activate` …
  are #135/#209's to ship."* Its Context (`:71`) points back at ADR 0039 §6.
- **`games/menu/README.md:107-112`:** *"A generic 'the runner reacts to a
  content-declared screen transition' mechanism is future work."*

#135 and #209 are both closed and shipped neither. So the design was never made, and an
implementation lane cannot invent it, because every plausible move trips a rule that
requires an ADR:

1. **No resolution path exists.** `src/runtime/manifest.zig:55` declares exactly one
   screen field — `hud: ?[]const u8`. `games/menu/screens/settings.zon` and
   `screens/controls.zon` are named by **no manifest field at all**; the only thing that
   references them is the hardcoded path in `tests/menu_acceptance.zig:70,308`. The
   engine cannot resolve *any* identifier to those files. Fixing that is a `game.zon`
   format/package-layout change ⇒ ADR (CLAUDE.md).
2. **`next_screen` is a `games/menu` convention, not an engine concept.**
   `rules.lua:61`: `next_screen = 0, -- 0 = none, 1 = main menu, 2 = settings,
   3 = controls`. Content-defined integer sentinels. Any `src/**` code that maps `3` to
   `screens/controls.zon` hardcodes one package's private numbering into the engine —
   **invariant #6**. Turning it into something the engine *can* resolve changes the
   handler-table contract and `rules.lua` ⇒ ADR 0003 §5's discipline applies.
3. **Ownership and lifetime are a real design problem, not a detail.** `HudState`
   (`main.zig:572-589`) owns **one** `ui.Screen`, plus a font-glyph atlas merged into
   the scene atlas, built once at load (`:597-608`) and uploaded to a GPU texture
   (`:1067-1077`). `UiInput.setScreen` (`src/engine/ui_dispatch.zig:71`) **borrows**
   `*const ui.Screen`. A live swap must decide who owns the screen set, whether a screen
   may be freed while the sim borrows it, and what a second screen's glyphs do to an
   already-uploaded atlas.

This ADR designs the mechanism and implements none of it. It turns #249 back into the
wiring task it was originally scoped as.

Forces settled elsewhere, applied here rather than re-litigated:

- **Files are the source of truth (invariant #1)** — a screen is a ZON file; its
  *presence* should be its declaration wherever that is workable (ADR 0038 §4).
- **Genre lives in content (invariant #6)** — the engine may know "a screen", "a named
  screen the package requested", and "the initially active one". It may never know that
  a screen called `controls` exists, nor that `3` means anything.
- **Convention over configuration for bulk content (ADR 0038 §4)** — the manifest names
  identity, entry points, and cross-cutting settings; it does **not** enumerate a
  package's scenes or prototypes. Those are globbed from kind-directories.
- **ADR 0038 §2 already anticipated this exact moment:** *"HUD stays a single named
  `hud.zon` (one screen today); it earns a `hud/` directory only when a game has several
  screens (add-when-needed)."* `games/menu` has several screens and already shipped them
  in a directory. The add-when-needed trigger has fired.
- **One active screen (ADR 0039 §6)** — unchanged by this ADR; see §6.
- **Full-reload, last-good-wins, at a tick boundary (ADR 0005 §2/§3)** — the model ADR
  0041 §3 already reused for the action-map swap; reused again here for the screen swap.
- **The engine reads content's proposed data off handler fields; content never touches a
  file (ADR 0003 §7, ADR 0041 §4, #135)** — the persistence-driver seam generalises to
  any "content declares intent as plain data, an engine-side driver acts on it".
- **No speculative flexibility (CLAUDE.md)** — design the switch a real package needs,
  not the stack none does (§6).

## Decision

### 1. The screen set is a globbed `screens/` kind-directory; `hud` names the initial one

**`game.zon` gains no field.** The screen set is discovered, not enumerated — the same
answer ADR 0038 §4 already gives for scenes, prototypes, and scripts.

- **The set** is the sorted, byte-lexicographic glob of `<pkg>/screens/*.zon` (ADR 0038's
  sort rule; the existing `watchDir` helper at `main.zig:1319` globs exactly this shape,
  one level, missing directory silently skipped) **∪ the file `manifest.hud` names**.
- **A screen's name is its basename without the extension.** `screens/settings.zon` →
  `"settings"`; `screens/main_menu.zon` → `"main_menu"`; `games/pacman/hud.zon` →
  `"hud"`. The filesystem guarantees names are unique within a directory; the engine
  invents no naming scheme and no registry file.
- **`hud`'s meaning widens; its type and its parse do not change.** It is now *"the
  screen that is active when the package loads"*. For every package shipping today that
  is verbatim what it already did: `games/pacman`/`games/snake` (`hud = "hud.zon"`) get
  a one-screen set and behave identically; `games/menu` (`hud = "screens/main_menu.zon"`)
  gets a three-screen set whose initial member is the file it already named. **No
  package's `game.zon` changes. There is no migration.**
- **Dedupe by path, collide by name.** `games/menu`'s `hud` path is *inside* the glob, so
  it resolves to the same set entry — loaded once, not twice. Two *different* paths
  yielding the same name (a root `hud.zon` alongside a `screens/hud.zon`) is a **hard
  load error naming both files** — never last-wins, mirroring ADR 0038 §2's
  duplicate-prototype-name rule for exactly the same reason (silent last-wins makes glob
  order meaningful).
- **A package with no `screens/` directory and no `hud`** has an empty set and no active
  screen: every path below is a no-op, which is every package except the three above.

**The format change this ADR makes is therefore small and layout-shaped, not
manifest-shaped:** `screens/` becomes a globbed kind-directory, and `hud` is documented
as the initial screen rather than "the HUD". That is still an ADR-triggering
package-format decision (CLAUDE.md), which is why it is pinned here.

**On the name `hud`.** It is now slightly narrow — `games/menu`'s front screen is not a
heads-up display, and `game.zon:14-19` already apologises for the abuse in a comment.
Renaming it (`screen`, `initial_screen`) would touch three packages' manifests and the
field's every reference for zero functional gain, and `data.parseLenient` ignores unknown
fields, so an alias period would silently give an old manifest *no* UI rather than an
error. **Declined:** keep `hud`, fix the doc comment. A rename stays available later as
an isolated content+field change with no design content.

### 2. The handler-table contract: `next_screen`, a **name**, engine-cleared, `""` = no request

The contract generalises ADR 0041 §4's driver seam (`input_override.zig`'s
`bindings_field`/`revision_field`) — content accumulates plain values in handler fields;
an engine-side driver reads them and acts. Nothing is added to the `mana` table, so per
ADR 0003 §5 and `src/script/CLAUDE.md`'s explicit statement of the same rule,
**`mana.version` stays 1**.

- **The field is `next_screen`**, a **string**: the *name* of the screen the package
  wants active next, in §1's basename vocabulary. `""` (the empty string) is the "no
  request" sentinel — the empty-string-sentinel convention `bind`/`text`/`id`
  (`src/ui/types.zig:118,121,128`) and `rules.lua`'s own `capture_action = ""` already
  use throughout.
- **A name, not an int.** An int sentinel *cannot* be made generic: `1`/`2`/`3` are
  meaningful only against a table that lives in `rules.lua`'s comments, so the engine
  would have to learn the numbering (invariant #6) or the package would have to publish
  it somewhere the engine reads — a registry file that duplicates what the filesystem
  already says (invariant #1). A name is resolved against files the engine globbed
  without the engine ever knowing which names exist: `"controls"` is an opaque content
  string to `src/**`, exactly as an action name is to the action map (ADR 0040 §3) and a
  `bind`/`id` string is to `ui.zig`.
- **The engine clears it.** After acting (or rejecting), the driver writes `""` back.
  Content never clears it. This is the one-shot analogue of ADR 0041 §4's revision
  counter: `bindings` is *state* the script must keep readable, so it earned a separate
  `bindings_revision` "commit this" field; `next_screen` is a *request*, consumed once,
  so consume-and-clear needs no second field and cannot desync from one. It is also
  idempotent by construction — a second poll before the script sets the field again sees
  `""` and does nothing, so no swap can fire twice for one activation.
- **The engine names the field, the same way it names `bindings`.** A `pub const
  next_screen_field = "next_screen"` in `src/**` is *not* an invariant-#6 violation, for
  the same reason `input_override.zig:66`'s `bindings_field = "bindings"` is not: it
  declares the engine's own generic contract ("the screen this package requests next"),
  naming no game, no screen, and no genre. What would violate #6 is resolving `3`, or
  knowing that `"controls"` exists.
- **An unknown name is last-good-wins** (ADR 0005 §3): log, keep the current screen,
  and **clear the field anyway** so a bad request is reported once rather than re-tried
  every tick — precisely `input_override.Outcome.rejected`'s rule ("the revision is
  consumed regardless").
- **A request naming the current screen is not special-cased**: it re-`setScreen`s,
  which resets focus and bumps the handle generation (§3). "Re-open this screen" landing
  on the first focusable widget is the intuitive reading, and a special case would buy
  nothing.
- **"Close the UI entirely" is deferred.** No package needs it: `games/menu`'s
  `start_button` sets `next_screen = 0` only as a stand-in for "a real runner would enter
  gameplay here", and a HUD never closes. `""` meaning *no request* (rather than *close*)
  is what keeps that door open: a distinguished name like `"none"` would collide with a
  real `screens/none.zon`, so a future close is its own field or `mana` call — additive
  either way. `UiInput.clearScreen` (`ui_dispatch.zig:80`) already exists for it.

**Engine seams this needs** (both are engine→state accesses, not script-callables, so
neither moves the version gate — `src/script/CLAUDE.md`): a scalar-string reader
`handlerFieldStr` and its write twin `setHandlerFieldStr`, on `State`/`LuaRuntime`, with
inert `NoopRuntime` mirrors, alongside the existing `handlerFieldInt` (`lua.zig:489`) and
`handlerFieldStrMap`/`setHandlerFieldStrMap` (`:519,572`). Two constraints those siblings
already encode and this one inherits: **copy the string out with the caller's allocator**
(never hand upward a borrow into Lua memory a later collection can invalidate), and
**read only a slot already of type `.string`** — `toString` coerces a number *in place*.
That second rule gives a free migration property worth stating: a script still holding
the old `next_screen = 0` int reads as *absent*, i.e. as no request — it never
misresolves to a screen named `"0"`.

**Content change this implies** (the wiring lane's, not this ADR's):
`games/menu/scripts/rules.lua` swaps its int sentinels for names (`""` / `"main_menu"` /
`"settings"` / `"controls"`), and `tests/menu_acceptance.zig:116`'s
`handlerFieldInt("next_screen") == 2` becomes the string assertion.

### 3. Resolution and ownership: **preload every screen**; a swap is one `setScreen` call

**All screens in the set are parsed at load and owned for the session.** `HudState`
(`main.zig:572-589`) grows from one `ui.Screen` to the set plus their names plus the
index of the active one; `loadHud` (`:597`) globs and parses instead of reading one path.

- **Nothing is freed at a swap, so the lifetime hazard does not exist.**
  `UiInput.setScreen` takes `*const ui.Screen` as a **borrow** (`ui_dispatch.zig:71`),
  documented as "borrows a `ui.Screen` the caller keeps alive for as long as it is the
  active screen". Load-on-switch means freeing the previously-active screen that
  `sim.ui_input.screen` still points at, or carefully ordering a free against a borrow
  the sim owns a copy of — a use-after-free waiting for the first mis-ordered edit, and
  a rule no test would catch under the default allocator. Preload makes a swap a pointer
  re-point into an array that outlives the sim: the exact ownership shape the load path
  already uses.
- **The cost preload pays is trivial and the saving load-on-switch buys is nil.** The
  entire in-repo screen corpus is three files of tens of widgets. A screen is parsed ZON
  — no textures, no GPU resources of its own.
  - *What would settle it the other way:* a package whose screen set is large enough for
    parse time or resident size to show up in a measurement (hundreds of screens, or
    screens carrying heavy embedded data). None exists; when one does, load-on-switch
    becomes a real option and this section is the thing to revisit — with the
    borrow-lifetime problem it re-opens as its actual cost, not its detail.
- **A swap requires no atlas rebuild and no re-upload.** This is a fact about the code,
  not a hope: `text.buildFontAtlas` (`src/engine/text.zig:192-203`) rasterizes the
  **whole font** — every glyph in `font.first_char .. count` — with no reference to any
  screen; `sprite.merge(scene_atlas, font)` is therefore screen-independent; and `image`
  widgets **emit nothing** today (`render_ui.zig:62,88` — "a later slice"). So no screen
  in any set can have a glyph the already-merged, already-uploaded atlas lacks. The
  atlas is built once, uploaded once, and outlives every swap — `main.zig:1067-1077`
  needs no change at all.
  - The day `image` widgets do resolve to atlas regions, a screen gains atlas content —
    and preload keeps that easy too, since every screen's images are known at load, when
    the atlas is built. Load-on-switch would make that change a re-upload per swap. A
    third, quiet argument for preload.
- **One active index, one source of truth.** The render projection (`projectHud`,
  `main.zig:616`) and `sim.ui_input`'s borrow must both derive from the *same* active
  index. Two independently-set fields would let the player navigate screen A while
  looking at screen B — the failure mode is silent, so the shape must forbid it rather
  than a test catch it.
- **Focus reset and handle staleness come free.** `setScreen` already does exactly the
  right thing on a swap: `self.focus = .{}` (the new screen starts with nothing focused;
  focus never carries across a swap — the widget it pointed at no longer exists) and
  `self.generation +%= 1` (every handle from the old screen reads stale, which is ADR
  0039 §2's already-pinned "bumps the generation once per screen load or hot-reload"
  semantics, with a swap simply being another such moment). **No new `UiInput` API.** The
  swap passes the current window size as the viewport, the same expression
  `main.zig:1058-1059` uses today.

**Where the pieces live.** The field-name constant and the poll/clear/resolve-a-name
policy are pure, testable-without-a-window logic and belong in `src/engine`, beside
`input_override.zig` — the same seam, the same test story (a suggested
`src/engine/screen_request.zig`; the name is the lane's call). The parsed screen set, the
glob, and the file I/O stay in `runtime`, where `HudState`/`loadHud` already live and
where `manifest.zig`'s stated split puts them ("parsing is pure … the runner does the
file I/O"). Neither half names a screen.

### 4. Dispatch ordering: the swap is a driver poll at the **tick boundary**, never inside dispatch

The screen swap happens **after `Sim.tick` returns**, not inside `on_activate`'s
dispatch. Two reasons, one of them a memory-safety one:

- **Re-entrancy.** `UiInput.pointerPress` lays the screen out, dispatches `on_click`,
  and *then* calls `focusAt` on that same `placed` slice (`ui_dispatch.zig:96-104`).
  A handler that swapped the screen mid-dispatch would leave the rest of the entry point
  walking a layout of a screen that is no longer active — and, under any future
  load-on-switch, of a screen that no longer exists. Handlers must not be able to move
  the ground under the dispatcher.
- **Consistency.** This is the model ADR 0005 §2/§3 fixes and ADR 0041 §3 already reused
  for the action map: content proposes, the engine re-resolves and swaps the borrow at a
  tick boundary, last-good-wins on a bad request. `#135`'s settings driver and
  `OverrideWriter.poll` are the same shape. A third driver on the same seam is a pattern,
  not an invention.

So the order per tick is: input edges → `UiInput` claims what it claims (ADR 0039 §3
unchanged) → `on_activate`/`on_click` run and set `next_screen` → `Sim.tick` returns →
drivers poll, in a **fixed order**, and the screen driver resolves + swaps. Nothing a
handler does is observed before it has finished. The drivers touch disjoint handler
fields and do not interact; the fixed order is for reproducibility, not correctness.
A swap therefore takes effect on the tick **after** the activation — one tick of latency,
invisible at 60 Hz and the same latency the action-map swap already accepts.

### 5. In-flight edges: a swap does **nothing** to them — and #213 is not this ADR's bug

**Rule: a swap never synthesizes, cancels, or re-routes an input edge.** Each edge is
claimed-or-not by whatever screen was active when it arrived; a later swap does not
retroactively change that, and does not fabricate a compensating edge.

The case #249's brief raises: the player presses Enter on SETTINGS → `UiInput` claims the
press → `on_activate` → swap at the boundary → the player *releases* Enter → `keyEdge`
returns `false` (ADR 0039 §1 claims **press** edges only, never releases) → the release
falls through to the **new** screen's package `on_key`. That is real. It is also
**exactly what happens today with no swap at all**: press Enter on any button on any
screen and the release already falls to gameplay `on_key`. #213 is a latent,
screen-independent defect in ADR 0039 §3's press-only claim rule — a swap does not create
it, does not worsen it, and fixing it here would fix it in the wrong place and hide it
from #213.

- **Deliberately not fixed here.** #213 owns it, and the fix (claim the release of any
  press the UI claimed) is a `UiInput` change orthogonal to screens. When #213 lands,
  this ADR's rule is unchanged and the phantom release simply stops existing.
- **Capture mode is not touched by a swap either.** An armed `mana.capture_input` (ADR
  0041 §1) survives a swap, because the engine cannot disarm it without desyncing the
  script's own `capture_action` mirror (`rules.lua:on_click` clears **both** the engine
  arm and its mirror — an engine-side auto-disarm would clear one and leave the other
  claiming to be armed). Content already owns this, and the arm/cancel triad is already
  sufficient: an armed capture cannot survive a **keyboard** navigation away (the Enter
  press on BACK is itself captured, hits `RESERVED_SOURCES`, and disarms), and a
  **pointer** click away is disarmed by `rules.lua`'s `on_click` today. The residual — a
  package that swaps by pointer while armed and does *not* cancel keeps capture armed
  onto the next screen — is a content bug the existing triad lets it avoid.
  - *This one is closer than the rest.* An engine-side "disarm on swap" is defensible and
    would make the hazard structurally impossible. What settles it: a second package that
    arms capture (one is not a pattern), or a UI-visible "listening for input" indicator
    — which would make the desync between engine arm and script mirror something a player
    can *see*, and at that point the mirror should probably not exist and the engine
    should own the disarm. Today there is one package, no indicator, and content that
    already handles it.

### 6. A switch, not a stack — and ADR 0039 §6 is not amended

Exactly **one screen is active at any time**, and a swap **replaces** it. ADR 0039 §6's
model stands verbatim.

This ADR reads ADR 0039 §6's exclusion as covering what it actually says — *modal/overlay
stacking, "multiple simultaneously active screens racing for focus"* — and fills the gap
neither ADR designed: *which* single screen is active, and how content changes it. That
distinction is the whole reason this fell through: 0039 excluded stacking, 0041 read the
exclusion as covering switching too and deferred to #135/#209, and #135/#209 shipped
neither.

**No stack, because no package needs one.** `games/menu`'s three screens are **peers** —
main ↔ settings ↔ controls — reachable by full replacement, with `back_button` naming
`main_menu` explicitly rather than popping to it. A stack would be pure speculation
(CLAUDE.md: *"Second concrete impl planned, or don't abstract"*).

- *What would settle it:* a package needing a screen rendered **over** another — a pause
  menu over live gameplay, a confirm dialog over settings. That is also the first case
  where a HUD and a menu must coexist, which is the same problem wearing a different hat
  and today's `hud`-is-the-one-screen model likewise cannot express. When one exists,
  a stack is a superset of this design, not a contradiction of it: the set, the names,
  the resolution, and the driver seam all survive; `next_screen` grows a push/pop
  vocabulary or gains a sibling field.

### 7. Explicitly out of scope

- **No implementation.** This ADR touches `src/**`, `games/**`, and `tests/**` not at all.
- **Screen hot reload.** The watch set (`syncWatchSet`, `main.zig:1293`) deliberately does
  **not** gain `screens/*.zon` here. Adding a file to the watch set with no reload path to
  act on it is the exact anti-pattern `watchActionMapFiles`'s own doc-comment warns
  against (*"watching the scene/script set there would report changes it cannot act on"*)
  — and `playLoop` has no HUD reload path today either, so the gap predates this ADR and
  is wider than it. When it lands, it is where §3's freed-borrow hazard genuinely
  arrives (a re-parsed screen *does* replace one the sim borrows), and ADR 0039 §2's
  generation bump already pins the handle semantics for it.
- **`quit_requested`.** `rules.lua:62` declares it and nothing consumes it either — the
  same shape of gap, a different field, and not #249's. It would be the same driver seam;
  it needs its own issue, and arguably not its own ADR once this one sets the pattern.
- **Closing the UI / "no active screen" as a content request** — §2; additive.
- **A screen stack, modals, overlays, HUD-and-menu simultaneously** — §6.
- **Fixing #213** — §5.
- **Pointer/click routing in `--play`** (`games/menu/README.md:113-115`: `pointerPress`
  exists and is tested but nothing feeds it a mouse position) — unrelated and unchanged;
  a swap works identically whether the activation arrived by key or by pointer.
- **A visual focus indicator** (#209's noted gap) — unrelated content/widget work.

## Alternatives considered

- **An explicit `screens` table in `game.zon`** (`.screens = .{ .settings =
  "screens/settings.zon", … }`, mirroring `input.zon`'s `.actions`). Rejected. It
  contradicts ADR 0038 §4 in its own words — the manifest *"does not enumerate the
  package's scenes or prototype files … the file's presence is the declaration (invariant
  #1)"* — and makes adding a screen a two-file edit forever. It is also the expensive
  option to build: content-authored, comptime-unknown field names cannot be decoded by
  `std.zon.parse`, so `manifest.zig` (today a single clean `data.parseLenient` call)
  would need `action_parse.zig`'s Zoir walk (`src/engine/action_parse.zig:10-16,61-88`)
  imported into it. All of that to name files that are already sitting in a directory
  whose name says what they are.
- **A list-shaped `screens` field** (`.screens = .{ .{ .name = "settings", .path = "…" },
  … }`). Rejected on the same ADR 0038 §4 grounds, though it is the cheapest of the
  manifest options (plain `parseLenient`, no Zoir). Its one genuine advantage over §1:
  a screen could live anywhere, so `hud`-outside-`screens/` would still be addressable by
  name without the basename rule. That advantage is worth nothing today — the only
  multi-screen package already keeps all three in `screens/`.
- **Keeping the int sentinel and adding an engine-side index → path table** (in the
  manifest, or by glob order). Rejected twice over: a *manifest* table is the enumeration
  ADR 0038 §4 rejects, wearing a worse type; a *glob-order* index makes renaming a file
  silently re-point every request in the script — a content bug with no error, exactly
  what ADR 0038 §2's fail-loud-on-duplicate rule exists to prevent. And "the engine knows
  what 3 means" is invariant #6 however the table is spelled.
- **A `mana.set_screen(name)` mutator instead of a handler field.** Rejected — it is the
  same shape ADR 0040 rejected for `mana.bind` and ADR 0041 §1 declined to reopen: it
  would have to take effect *inside* dispatch (§4's re-entrancy hazard) or secretly queue,
  which is the handler field with extra steps and a `mana.version` bump (ADR 0003 §5) for
  no capability. The field costs nothing and reuses a driver seam that already exists
  twice.
- **Swapping inside `on_activate`'s dispatch** (immediate, no tick of latency). Rejected —
  §4: it lets a handler invalidate the layout the dispatcher is mid-walk on, for a saving
  of one tick nobody can perceive.
- **Load-on-switch** (parse a screen when it is requested, free the old one). Rejected —
  §3: it re-introduces a borrow the sim holds into a freed allocation, to save a few
  kilobytes of parsed ZON. Revisit against a measurement, not a hunch.
- **Suppressing the in-flight release edge across a swap** (the swap consumes the pending
  release of the key that caused it). Rejected — §5: it fixes #213's symptom at one
  specific site, leaving the same bug everywhere else and making #213 look narrower than
  it is.

## Consequences

- **Easier:** #249 becomes the wiring task it was scoped as — glob a directory, parse a
  set, poll a string field at the tick boundary, call the `setScreen` that already exists.
  No `game.zon` edit, no package migration, no atlas work, no new `UiInput` API, no
  `mana` surface change. A content author gets a mechanism whose vocabulary is the
  filenames they already chose.
- **Harder / accepted:** `HudState`/`loadHud` grow from one screen to a set and a glob;
  `script`/`script_runtime` gain a scalar-string field reader and its write twin (with
  `NoopRuntime` mirrors); a third driver joins the tick-boundary poll; and the engine
  now owns a duplicate-screen-name load error that did not exist.
- **Committed to (once accepted):** the globbed `screens/` set and basename naming (§1);
  `hud` as the initial screen, unrenamed, with no manifest field added; the `next_screen`
  string field, `""` sentinel, and engine-clears rule (§2); preload-all ownership and
  swap-is-`setScreen` (§3); tick-boundary, post-dispatch swap (§4); the no-touch rule for
  in-flight edges and capture arming (§5); one active screen, no stack (§6).
- **`mana.version` stays 1** — no `mana` member is added, exactly as ADR 0039, 0040, and
  0041 each concluded for their own additions.
- **Determinism:** nothing here is hashed. A screen swap changes which cosmetic,
  hash-excluded UI tree is projected and focused (ADR 0034 §4, ADR 0039 §4); what a
  handler *body* mutates goes through the command buffer and is hashed as always. The
  glob is sorted (ADR 0038), the poll runs at a fixed point in a fixed driver order, and
  the swap consumes a deterministic field — so the same input trace against the same
  content produces the same swap on the same tick.
- **Unblocks #249**, and through it **#239** (the `games/menu` controls-screen remap flow,
  which cannot be played without reaching the controls screen) and **#201** (the remap
  epic). **#248** (script-backed `ui.Host`, so a rebind row can echo the player's actual
  binding) is a *file* conflict, not a design dependency: it touches `src/engine/ui*` and
  `main.zig`, which #249's implementation lane also owns, so the two must be serialised —
  but a `Host` reads values while a swap changes which screen is projected, and the only
  interaction is that a swap re-projects the new screen through the same `Host`.
  **#239 needs both.**
- **Explicitly not doing here:** see §7.

Cross-references: #249 (this decision), #135/#209 (closed, and between them the gap this
fills), #248 (`ui.Host` — the file-level co-owner of #249's lane), #239/#201 (unblocked),
#213 (the in-flight release edge §5 leaves alone); builds on ADR 0038 (package layout —
§2's "it earns a directory when a game has several screens" is the trigger this fires,
§4's glob-don't-enumerate convention is §1's argument), ADR 0039 (UI input events — §6's
one-active-screen model kept, §2's handle-generation semantics reused for the swap, §3's
dispatch ordering unchanged), ADR 0041 (§4's handler-field driver seam generalised, §3's
tick-boundary borrow swap reused, §1's capture mode §5 leaves armed), ADR 0034 (UI
subsystem direction — §4's cosmetic/hash-exclusion treatment), ADR 0005 (full-reload,
last-good-wins, tick boundary), ADR 0003 (Lua scripting API — §5's additive versioning,
§7's sandbox that forces the engine-side driver), ADR 0040 (the opaque-content-string
precedent a screen name follows).
