# Bloom HPS (AmIHealing) — Extensive Code Walkthrough

An Elder Scrolls Online addon that measures and displays your **Healing Per Second (HPS)** and **Shielding Per Second (SPS)**, tracks damage mitigated by your shields, and keeps a running "personal best" history of Battleground performance. It is built to work on both **PC** and **Console (Xbox/PlayStation)**, and is safe to use in PvP.

This document explains, in detail and in order, how every piece of the addon works — from the manifest file down to the individual Lua functions — so that the code can be understood, maintained, or extended by anyone, including readers with little ESOUI/Lua experience.

---

## Table of Contents

1. [What This Addon Does](#1-what-this-addon-does)
2. [File & Folder Structure](#2-file--folder-structure)
3. [The Manifest File (`HPSMeter.addon`)](#3-the-manifest-file-hpsmeteraddon)
4. [High-Level Architecture](#4-high-level-architecture)
5. [Step-by-Step: Addon Startup (`OnAddOnLoaded`)](#5-step-by-step-addon-startup-onaddonloaded)
6. [Step-by-Step: State & Default Settings](#6-step-by-step-state--default-settings)
7. [Step-by-Step: Utility Functions](#7-step-by-step-utility-functions)
8. [Step-by-Step: Building the On-Screen UI (`CreateUI`)](#8-step-by-step-building-the-on-screen-ui-createui)
9. [Step-by-Step: The Healing Pipeline](#9-step-by-step-the-healing-pipeline)
10. [Step-by-Step: The Shielding Pipeline](#10-step-by-step-the-shielding-pipeline)
11. [Step-by-Step: Mitigation Tracking (Damage Absorbed by Shields)](#11-step-by-step-mitigation-tracking-damage-absorbed-by-shields)
12. [Step-by-Step: Rolling Windows ("Buckets") Explained](#12-step-by-step-rolling-windows-buckets-explained)
13. [Step-by-Step: Rendering the Label Text (`UpdateDisplay`)](#13-step-by-step-rendering-the-label-text-updatedisplay)
14. [Step-by-Step: Resetting & Idle Auto-Reset](#14-step-by-step-resetting--idle-auto-reset)
15. [Step-by-Step: Battleground Best-Stats History](#15-step-by-step-battleground-best-stats-history)
16. [Step-by-Step: Settings Menu (LibAddonMenu-2.0)](#16-step-by-step-settings-menu-libaddonmenu-20)
17. [Step-by-Step: Slash Commands](#17-step-by-step-slash-commands)
18. [Enemy/Allied HP Tracking (`OnPowerUpdate`) — Experimental Stub](#18-enemyallied-hp-tracking-onpowerupdate--experimental-stub)
19. [SavedVariables Explained](#19-savedvariables-explained)
20. [Textures](#20-textures)
21. [Known Limitations & Stubs](#21-known-limitations--stubs)
22. [Installation](#22-installation)
23. [Quick Function Reference Table](#23-quick-function-reference-table)

---

## 1. What This Addon Does

Bloom HPS places a small, movable, scalable text label on your screen that continuously reports:

- **HPS** — your healing output, averaged over a rolling time window (default 10 seconds).
- **SPS** — your shielding output, averaged over its own rolling time window (default 10 seconds).
- **Group Heal / Group Shield** — cumulative healing/shielding applied to **other** people.
- **Personal Heal / Personal Shield** — cumulative healing/shielding applied to **yourself**.
- **Mitigated %** — the percentage of incoming damage to your shielded allies that was absorbed by your shields rather than landing as real damage.
- **Overall HPS / Overall SPS** — lifetime average rates since the counters were last reset.

It also remembers your **best-ever Battleground run** (highest total healing, shielding, and mitigation percentage) across play sessions, using ESO's `SavedVariables` system, and exposes a full settings panel (position, scale, color, timers) through **LibAddonMenu-2.0**, plus a set of chat **slash commands**.

---

## 2. File & Folder Structure

```
AmIHealing/
├── HPSMeter.addon      ← Manifest: tells ESO the addon's name, version, dependencies, entry file
├── HPSMeter.lua        ← All addon logic (1,242 lines) — the only script file
├── README.md           ← This document
└── textures/
    ├── heart.dds        ← Icon shown next to the HPS (healing) label
    └── shield.dds        ← Icon shown next to the SPS (shielding) label
```

> **Note on folder vs. internal name**: The folder on disk is `AmIHealing`, but the addon's registered internal name (used in `SLASH_COMMANDS`, event names, and the `OnAddOnLoaded` check) is `"HPSMeter"`, and its display title (shown in the in-game Addons list) is **"Bloom HPS"**. These three names refer to the same addon.

---

## 3. The Manifest File (`HPSMeter.addon`)

```ini
## Title: Bloom HPS
## APIVersion: 101046
## AddOnVersion: 2.1
## Author: Vixen Hunny
## SavedVariables: HPSMeterSavedVars HPSMeterHealingData
## DependsOn: LibAddonMenu-2.0
## Description: HPS and SPS Meter

HPSMeter.lua
```

Every `.addon` file is read by the ESO client before any Lua runs. Each line means:

| Directive | Purpose |
|---|---|
| `## Title:` | Name shown in the in-game Addons menu. |
| `## APIVersion:` | The ESO API version this addon was written/tested against. If the client's live API version doesn't match, ESO shows the addon as "out of date" (it can still be force-enabled). |
| `## AddOnVersion:` | A version number for update-tracking purposes. |
| `## Author:` | Credit shown in the Addons list. |
| `## SavedVariables:` | Declares the **global Lua table names** that ESO is allowed to persist to disk between sessions. Here, `HPSMeterSavedVars` (settings + BG history) and `HPSMeterHealingData` (reserved/unused placeholder) are whitelisted. Only tables listed here may be saved — this is a security/sandbox rule enforced by the client. |
| `## DependsOn:` | Declares a **hard dependency**. ESO will not load `HPSMeter.lua` unless `LibAddonMenu-2.0` is also installed and enabled, because the settings panel (`HPSMeterUI:CreateLAM`) calls into that library. |
| `## Description:` | One-line summary shown in the Addons list tooltip. |
| `HPSMeter.lua` (bare line, no `##`) | The list of Lua files to load, in order. Since there's only one, the entire addon lives in a single script. |

---

## 4. High-Level Architecture

The whole addon is organized around one global table, **`HPSMeterUI`**, which acts as both the "class" (via `function HPSMeterUI:Method()` syntax) and the single source of truth for all runtime state (counters, UI control references, saved settings). There is no object instantiation — `HPSMeterUI` *is* the single instance.

Data flows in one direction:

```
ESO Combat/Attribute Events
        │
        ▼
Event handler functions (GetHealing, OnShieldMitigated, OnVisualAddedOrUpdated, ...)
        │  (filter, validate, extract hit amount)
        ▼
Rolling "bucket" arrays + running totals (HPSMeterUI.buckets, .shieldBuckets, .overallHealingTotal, ...)
        │
        ▼
HPSMeterUI:UpdateDisplay()  (recomputes HPS/SPS/mitigated % from the buckets/totals)
        │
        ▼
HPSMeterUI:SetHealingLabelText() → on-screen CT_LABEL controls
```

Three independent subsystems share this pipeline:

1. **Healing** — driven by `EVENT_COMBAT_EVENT` heal results.
2. **Shielding** — driven by a combination of `EVENT_COMBAT_EVENT` (to know *who* you shielded) and `EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED/UPDATED/REMOVED` (to know the *actual current shield amount* on that unit, so deltas can be measured).
3. **Mitigation** — driven by `EVENT_COMBAT_EVENT` damage results, but only counted for units you are currently shielding.

---

## 5. Step-by-Step: Addon Startup (`OnAddOnLoaded`)

Located near the bottom of `HPSMeter.lua`. This is the entry point — nothing else in the file runs until ESO fires `EVENT_ADD_ON_LOADED` for this addon.

```lua
local function OnAddOnLoaded(event, addonName)
    if addonName ~= "HPSMeter" then return end
    ...
end
EVENT_MANAGER:RegisterForEvent("HPSMeter", EVENT_ADD_ON_LOADED, OnAddOnLoaded)
```

The very last line of the file registers the callback. `EVENT_ADD_ON_LOADED` fires once *for every addon the game loads* (including other people's), so the first line of the handler — `if addonName ~= "HPSMeter" then return end` — guards against reacting to the wrong addon.

Once the name matches, startup proceeds in this exact order:

1. **Load or create saved settings**
   ```lua
   HPSMeterUI.saved = ZO_SavedVars:NewAccountWide("HPSMeterSavedVars", 2, nil, HPSMeterUI.defaults)
   ```
   This pulls the player's saved settings table from disk (account-wide, i.e. shared by all characters), or creates it from `HPSMeterUI.defaults` the first time the addon ever runs. The `2` is the SavedVariables schema version.

2. **One-time theme/color migration** — if `themeVersion` is missing or `< 1`, any old default placeholder color (`"ffff00"`, plain yellow) is replaced with the addon's real default palette (mint green `9ff8ba`, pale blue `b8f7ff`, pale green `d6ffd6`), then `themeVersion` is stamped to `1` so this migration never runs again.

3. **Initialize the HPS rolling buckets**: `for i=1,HPSMeterUI.saved.window do HPSMeterUI.buckets[i] = 0 end`.

4. **Print `"Loaded"` to chat** as a confirmation the script initialized.

5. **Register all slash commands** (`/bloomhpslink`, `/bloomhpsstats`, etc. — see [Section 17](#17-step-by-step-slash-commands)).

6. **Unregister the `EVENT_ADD_ON_LOADED` listener** — it has done its job and won't fire again for this addon this session.

7. **Build the UI** inside a `pcall(...)` (protected call) so that if control creation throws an error, it's caught and printed instead of crashing the whole UI layer:
   ```lua
   local ok, err = pcall(function() HPSMeterUI:CreateUI() end)
   if not ok then d("[BloomHPS] CreateUI error: " .. tostring(err)) end
   ```

8. **Register all combat/attribute-visual events** that drive mitigation, shielding, and healing tracking (see Sections 9–11).

9. **Build the LibAddonMenu settings panel**, also wrapped in `pcall`:
   ```lua
   local ok2, err2 = pcall(function() HPSMeterUI:CreateLAM() end)
   ```

10. **Register the healing combat-event listener** (`GetHealing`) filtered to only fire when **you** are the source of the action.

11. **Register two 1-second recurring timers** via `EVENT_MANAGER:RegisterForUpdate`:
    - `"HPSMeter_SPS_Tick"` — advances both rolling windows every second (so HPS/SPS decay toward 0 even if no new heals/shields land) and refreshes the label text.
    - `"HPSMeterIdleReset"` — checks how long it's been since the last heal; if it exceeds the configured idle timeout, the whole meter resets (see [Section 14](#14-step-by-step-resetting--idle-auto-reset)).

12. **Register `EVENT_BATTLEGROUND_STATE_CHANGED`** — when a Battleground match ends (`BATTLEGROUND_STATE_FINISHED`/`BATTLEGROUND_STATE_POSTGAME`), the addon saves your stats into the all-time history, then resets the live counters for the next match.

---

## 6. Step-by-Step: State & Default Settings

Near the top of the file:

```lua
HPSMeterUI = {}
local tooltip = nil
local LAM = LibAddonMenu2 or {}

HPSMeterUI.defaults = {
    showLabel = true,
    labelX = 300, labelY = 200,
    window = 10, scale = 0.5, labelColor = "9ff8ba",
    showShields = true,
    shieldLabelx = 350, shieldLabely = 200,
    shieldWindow = 10, shieldScale = 0.5, shieldColor = "b8f7ff",
    showOverall = true, overallColor = "d6ffd6",
    resetTimer = 300,
    topHealing = 0, topShielding = 0, topMitigation = 0,
    bgHistory = {}
}
```

`HPSMeterUI.defaults` is the template used the first time `ZO_SavedVars:NewAccountWide(...)` runs — it is **not** the live settings table. The live, persisted table is `HPSMeterUI.saved`, created in `OnAddOnLoaded`. Every setting the user changes in the options menu writes into `HPSMeterUI.saved.*`, which ESO automatically serializes to the SavedVariables file on logout.

Below the defaults table, a long block of **plain (non-persisted) runtime state** is initialized directly on `HPSMeterUI`. These are working variables, reset every reload or by `:Reset()`, including:

| Field | Meaning |
|---|---|
| `buckets`, `bucketStartSec`, `bucketTotal` | The HPS rolling window (array of per-second heal totals, the second it last advanced, and the running sum). |
| `shieldBuckets`, `shieldBucketStartSec`, `shieldBucketTotal` | Same idea, for SPS. |
| `overallHealingTotal`, `overallShieldingTotal` | Lifetime totals since the last reset (used for "Overall HPS/SPS"). |
| `personalHealTotal`, `groupHealTotal`, `personalShieldTotal`, `groupShieldTotal` | Split totals: healing/shielding applied to yourself vs. to others. |
| `overallMitigatedTotal`, `overallPostShieldDamageTotal` | Damage absorbed by your shields vs. damage that still got through after a shield was present — used to compute "Mitigated %". |
| `myShieldedTargets` | A table keyed by unit name, tracking who currently has a shield from you, its last known value, and an expiry timestamp (`activeUntil`). |
| `firstHealTime`, `firstShieldTimeMs`, `lastHealTime`, `lastShieldTime` | Timestamps (via `GetGameTimeMilliseconds()`) used to compute elapsed time for lifetime averages and to drive the idle-reset timer. |
| `enemyHP`, `alliedHP`, `enemyUnits`, `enemyHealing`, `enemyLinesControls`, `graphNumbers`, `pvpEvents` | State for the experimental/unused enemy-HP tracking stub (see [Section 18](#18-enemyallied-hp-tracking-onpowerupdate--experimental-stub)). |
| `idleTimeout` | Hard-coded 300000 ms (5 minutes) fallback; the *actual* idle timeout used at runtime comes from `HPSMeterUI.saved.resetTimer` (user-configurable, also defaults to 300 **seconds**). |

> **Design note**: Keeping everything as fields on one global table (instead of local variables per function) is what lets every function — UI, combat handlers, settings callbacks, slash commands — read and write the same live state without needing to pass data around.

---

## 7. Step-by-Step: Utility Functions

These small helpers sit near the top of the file and are used throughout:

### `HPSMeterUI:IsPvP()`
```lua
function HPSMeterUI:IsPvP() return true end
```
Always returns `true`. This is a vestigial/simplified stub — the addon no longer branches its behavior based on zone type, so this always-true function effectively means "always run PvP-safe behavior." It is defined but not meaningfully branched upon elsewhere in the current code.

### `FormatShortNumber(n)`
Converts a raw number into a compact, human-readable string, the same way DPS/HPS meters typically do:
- `>= 1,000,000,000` → formatted with a `b` suffix (billions)
- `>= 1,000,000` → formatted with an `m` suffix (millions)
- `>= 1,000` → formatted with a `k` suffix (thousands)
- otherwise → the plain integer as a string

It picks between a whole-number format (`%.0f`) and a one-decimal format (`%.1f`) depending on whether the value crosses the *next* order-of-magnitude threshold (e.g. `9,999` → `"10.0k"`-style rounding behavior, `12,000` → `"12k"`). This keeps on-screen numbers short regardless of how large your healing gets.

### `HexToRGBA(hex, alpha)`
Converts a 6-character hex color string (e.g. `"9ff8ba"`, as stored in settings/editboxes) into the four `0–1` floating point R, G, B, A values that ESO's `SetColor`/`SetCenterColor` API expects. Falls back to opaque white (`ffffff`) if the string is missing or not exactly 6 hex characters.

### `StripESOColorCodes(text)`
A pass-through function (currently returns the text unchanged). It exists as a named seam for the "shadow" label text — the shadow/outline copy of each label is meant to be colorless, so this function is where color-code stripping would be implemented if ESO's `|cRRGGBB...|r` codes ever needed to be removed before drawing the shadow.

### `HPSMeterUI:SetHealingLabelText`, `:SetShieldLabelText`, `:SetHealingOverallText`
Each sets text on a *pair* of controls: the real label (colored, via `SetText`) and its "shadow" twin, one pixel offset down-and-right, using the stripped (shadow-safe) text, to create a drop-shadow effect that keeps text readable over any background.

---

## 8. Step-by-Step: Building the On-Screen UI (`CreateUI`)

`HPSMeterUI:CreateUI()` runs once, from `OnAddOnLoaded`. It programmatically creates every visual element (ESO addons typically do this in Lua rather than XML when no `.xml` file is present, as is the case here). Step by step:

1. **Top-level window** — `HPSMeterControl`, a borderless, full-screen-anchored, mouse-disabled container (`SetMouseEnabled(false)` so it never blocks clicks) that everything else anchors to.

2. **Backdrop panel** (`HPSMeterBackdrop`) — a `CT_BACKDROP` control giving the label a translucent dark-green rounded background (`132c1f` center, `8ecf9a` edge) so text is legible over any game scene. Its size/position are computed dynamically in `RefreshWardenThemeLayout()` (see below), not fixed here.

3. **Title label** (`HPSMeterTitleLabel`) and two decorative "flower" labels (`HPSMeterFlowerTop` / `HPSMeterFlowerBottom`) — currently created with empty text (`SetText("")`), i.e. reserved slots for a themed header/footer that isn't populated with content in the current version, but the layout code (`RefreshWardenThemeLayout`) still positions and shows/hides them.

4. **Main HPS label pair** — `HPSMeterLabel` (visible, colored text) and `HPSMeterLabelShadow` (the drop-shadow copy, anchored 1px down-right of the real label, dark green `0.05, 0.14, 0.08`). Both use font `"$(MEDIUM_FONT)|<size>|outline"`, where `<size>` is `math.max(14, math.floor(22 * scale))` — i.e. the font size scales with the user's configured `scale`, but never shrinks below 14px. Position comes from `saved.labelX` / `saved.labelY`.

5. **Healer icon** (`HPSMeterHealerIcon`) — a `CT_TEXTURE` control using `AmIHealing/textures/heart.dds`, anchored to the right of the main label at 60% opacity (`SetAlpha(0.6)`), scaled with the label.

6. **"Overall" label pair** — `HPSMeterOverallLabel` / shadow, anchored directly beneath the main label (`BOTTOMLEFT` → `TOPLEFT`, 2px gap), for the lifetime Overall HPS/SPS line.

7. **Second healer icon** (`HPSMeterHealerIconOverall`) next to the overall label.

8. **Shield label pair** (`HPSMeterShieldLabel` / shadow) — positioned independently via `saved.shieldLabelx` / `saved.shieldLabely`, its own scale (`saved.shieldScale`), and its own shadow color (dark blue `0.04, 0.12, 0.16`).

9. **Shield icon** (`HPSMeterFlowerIcon`) using `AmIHealing/textures/shield.dds`.

10. **Important consolidation step**: immediately after creating the *separate* shield/overall controls, the code explicitly re-hides them:
    ```lua
    if HPSMeterUI.shieldControl then HPSMeterUI.shieldControl:SetHidden(true) end
    if HPSMeterUI.shieldShadowControl then HPSMeterUI.shieldShadowControl:SetHidden(true) end
    if HPSMeterUI.flowerIcon then HPSMeterUI.flowerIcon:SetHidden(true) end
    if HPSMeterUI.labelOverallControl then HPSMeterUI.labelOverallControl:SetHidden(true) end
    if HPSMeterUI.labelOverallShadowControl then HPSMeterUI.labelOverallShadowControl:SetHidden(true) end
    if HPSMeterUI.healerIcon then HPSMeterUI.healerIcon:SetHidden(true) end
    if HPSMeterUI.healerIconOverall then HPSMeterUI.healerIconOverall:SetHidden(true) end
    ```
    This reflects a design evolution: HPS, SPS, Mitigated %, and Overall HPS/SPS used to be *separate on-screen labels*, but the current `UpdateDisplay()` (Section 13) merges **everything into one multi-line string drawn by the single main label control** (`labelControl`). The standalone shield/overall/icon controls and their settings sliders are still created and still exist in the options menu (for position/scale/color tuning of the *merged text's* colors), but the controls themselves are force-hidden so they don't double-render empty/duplicate boxes. Only `labelControl` + `labelShadowControl` (and the heart icon) are actually shown.

11. **Finish** by calling `HPSMeterUI:RefreshWardenThemeLayout()` (sizes/positions the backdrop panel behind the text) and `HPSMeterUI:UpdateDisplay()` (renders initial text immediately, so the label isn't blank until the first combat event).

### `RefreshWardenThemeLayout()`
Recomputes the backdrop panel's size/position every time a layout-affecting setting changes (scale, position, show/hide). If `showLabel` is off, it hides the backdrop and decorative elements and exits early. Otherwise it computes a panel sized to comfortably fit the merged multi-line text (`520 * scale` wide, `90 * scale` tall, plus padding) and anchors it `18px`/`24px` up-and-left of the label's top-left corner so the text has breathing room inside the panel.

---

## 9. Step-by-Step: The Healing Pipeline

### 9.1 Registration
```lua
EVENT_MANAGER:RegisterForEvent("HPSMeter_Heal", EVENT_COMBAT_EVENT, GetHealing)
EVENT_MANAGER:AddFilterForEvent("HPSMeter_Heal", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
```
This tells ESO: "Call `GetHealing` for every combat event, but only when the *source* of the event is the player character." This filter alone already excludes heals done by other players or NPCs — the meter only ever measures **your own** output.

### 9.2 `GetHealing(eventCode, result, isError, ..., targetName, ..., hitValue, ...)`
A global function (not a method on `HPSMeterUI`) matching ESO's `EVENT_COMBAT_EVENT` callback signature. Step by step:

1. **Bail out on errors**: `if isError then return end`.
2. **Filter by result type** using a lookup table built once at file scope:
   ```lua
   local healResults = {
       [ACTION_RESULT_HEAL] = true,
       [ACTION_RESULT_CRITICAL_HEAL] = true,
       [ACTION_RESULT_HOT_TICK] = true,
       [ACTION_RESULT_HOT_TICK_CRITICAL] = true,
   }
   ...
   if not healResults[result] then return end
   ```
   This covers direct heals, critical heals, and heal-over-time ticks (both normal and critical), while ignoring every other combat result code (damage, misses, buffs, etc.).
3. **Bail out if the label is hidden** (`if not HPSMeterUI.saved.showLabel then return end`) — no point tracking numbers nobody will see... though note this *does* mean turning the label off also stops the Overall/lifetime counters from accumulating, which is a notable behavioral coupling to be aware of.
4. **Lazily initialize the rolling window** the first time a heal lands (`if HPSMeterUI.bucketStartSec == 0 then HPSMeterUI:InitBuckets() ... end`).
5. **Advance the rolling window** to the current second (`HPSMeterUI:AdvanceBuckets(nowSec)`) — see [Section 12](#12-step-by-step-rolling-windows-buckets-explained) for exactly what this does.
6. **Add the heal amount** (`hitValue`) to:
   - the current (last) bucket slot,
   - `bucketTotal` (the rolling-window sum),
   - `overallHealingTotal` (the lifetime/session sum).
7. **Update `lastHealTime`** to the current game time — this timestamp is what the idle-reset timer watches.
8. **Split personal vs. group healing**: the target's name is compared (after `zo_strformat` normalization) against the player's own name. If they match, the amount goes to `personalHealTotal`; otherwise it goes to `groupHealTotal`.
9. **Call `HPSMeterUI:UpdateDisplay()`** to immediately refresh the on-screen text with the new numbers.

---

## 10. Step-by-Step: The Shielding Pipeline

Shielding is harder to measure than healing because ESO's combat log reports *that* a shield effect was gained, but not reliably *how much absorption value* it granted at every tick. The addon solves this with a **two-event combination**:

### 10.1 Event A — "Who did I just shield?" (`EVENT_COMBAT_EVENT`)
```lua
EVENT_MANAGER:RegisterForEvent("HPSMeter_ShieldCombat", EVENT_COMBAT_EVENT, function(_, result, _, _, _, _, _, _, targetName, _, _, _, _, _, _, _, _)
    HPSMeterUI:GetShielding(result, targetName)
end)
EVENT_MANAGER:AddFilterForEvent("HPSMeter_ShieldCombat", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
```
Filtered to only fire when **you** are the source. `HPSMeterUI:GetShielding(result, targetName)`:
```lua
function HPSMeterUI:GetShielding(result, targetName)
    if result ~= ACTION_RESULT_EFFECT_GAINED and result ~= ACTION_RESULT_EFFECT_GAINED_DURATION then return end
    local tName = zo_strformat("<<C:1>>", targetName)
    if not tName or tName == "" then return end
    local entry = HPSMeterUI.myShieldedTargets[tName]
    if not entry then
        entry = { last = 0, activeUntil = 0 }
        HPSMeterUI.myShieldedTargets[tName] = entry
    end
    entry.activeUntil = GetGameTimeMilliseconds() + 20000
end
```
When you cast a shielding ability and it registers as a gained effect on `targetName`, that name is added to `myShieldedTargets` (if not already present) and marked "active" for the next **20 seconds** — long enough to cover typical PvP ward durations. This table is what later lets the mitigation tracker (Section 11) know *whose* incoming damage hits should count as "mitigated by me."

### 10.2 Event B — "How much shield value does that unit actually have right now?" (`EVENT_UNIT_ATTRIBUTE_VISUAL_*`)
```lua
local function OnVisualAddedOrUpdated(_, unitTag, visualType, _, _, _, oldOrValue, newOrMax, oldMaxOrNil, _)
    if visualType ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
    local value = oldMaxOrNil == nil and oldOrValue or newOrMax
    HPSMeterUI:UpdateShieldVisuals(unitTag, value)
end
local function OnVisualRemoved(_, unitTag, visualType, _, _, _, _, _)
    if visualType ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
    HPSMeterUI:UpdateShieldVisuals(unitTag, 0)
end
EVENT_MANAGER:RegisterForEvent("HPSMeter_ShieldVisualAdd", EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, OnVisualAddedOrUpdated)
EVENT_MANAGER:RegisterForEvent("HPSMeter_ShieldVisualUpd", EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, OnVisualAddedOrUpdated)
EVENT_MANAGER:RegisterForEvent("HPSMeter_ShieldVisualRem", EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED, OnVisualRemoved)
```
ESO fires these events for **any unit currently in your client's awareness** (not just your own shields) whenever their shield "visual" (the absorb-shield health-bar overlay) changes. The handler:
- Ignores anything that isn't `ATTRIBUTE_VISUAL_POWER_SHIELDING`.
- Figures out the correct "current value" depending on whether this is an ADD (value is in `oldOrValue`) or an UPDATE (value is in `newOrMax`).
- Passes it to `HPSMeterUI:UpdateShieldVisuals(unitTag, value)`.
- On REMOVE, explicitly passes `0` (shield gone).

### 10.3 `HPSMeterUI:UpdateShieldVisuals(unitTag, newShieldValue)` — the core shield-delta calculator
1. Exits immediately if `showShields` is off.
2. Resolves the unit's **character name** and **@displayName**, and checks whether *either* form exists as a key in `myShieldedTargets` (the table populated in step 10.1). **This is the critical gate: visual-shield updates for units you never shielded are ignored entirely**, so you never get credit for someone else's shields (e.g., another healer's wards) landing on a shared target.
3. If no match is found, returns without doing anything.
4. Otherwise, computes `delta = newValue - oldValue` (`oldValue` being the previously recorded `entry.last`), and updates `entry.last = newValue`.
5. Refreshes `entry.activeUntil` — `nowMs + 1500` if the shield is still present (a much shorter 1.5s window than the 20s from step 10.1, since this is now tracking "is this exact shield instance still alive" for mitigation purposes), or `0` if the new value is `0`.
6. **If `delta < 0` and the new value is `0`** (the shield fully depleted/expired), the unit is removed from `myShieldedTargets` entirely and the function returns — a *decrease* in shield value by itself (shield ticking down from mitigating damage, or expiring) is **not** counted as negative "shielding" output; only *increases* add to your SPS.
7. Otherwise (shield value increased, i.e. you topped it up or it's a fresh application), the **positive** `delta` is:
   - Lazily initializes the shield rolling-window buckets if this is the very first shield ever applied this session.
   - Added to the current shield bucket and `shieldBucketTotal` (rolling SPS window).
   - Added to `overallShieldingTotal` (lifetime/session SPS).
   - Split into `personalShieldTotal` (if `unitTag == "player"`) or `groupShieldTotal` (shields on anyone else).
   - Used to set `firstShieldTimeMs` the first time (for lifetime average calculations) and `lastShieldTime` (currently tracked but not wired into the idle-reset timer the way `lastHealTime` is).
   - Triggers `HPSMeterUI:UpdateDisplay()` to refresh the label immediately.

> **Why this two-event design?** Combat log heal events give you a precise "amount healed" number per tick for free. Shields don't work that way in the API — there's no "amount shielded" combat-log number comparable to a heal tick. So the addon instead **watches the shield's displayed value rise and fall over time** and treats *increases* as "you just applied N points of new shielding," which is the best approximation available without reading internal ability tooltips.

---

## 11. Step-by-Step: Mitigation Tracking (Damage Absorbed by Shields)

This subsystem answers: *"Of all the damage aimed at people I've shielded, how much did my shields actually stop?"*

### 11.1 Shield-absorbed hits
```lua
EVENT_MANAGER:RegisterForEvent("HPSMeter_ShieldMitigated", EVENT_COMBAT_EVENT,
    function(_, result, _, _, _, _, _, _, targetName, _, hitValue, _, _, _, _, _, _, _)
        HPSMeterUI:OnShieldMitigated(result, targetName, hitValue)
    end
)
EVENT_MANAGER:AddFilterForEvent("HPSMeter_ShieldMitigated", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_DAMAGE_SHIELDED
)
```
Filtered at the engine level to only ever receive `ACTION_RESULT_DAMAGE_SHIELDED` results (damage that was absorbed by *some* shield, not necessarily yours — "a lot of spam" the code comment warns about, hence the aggressive filter).

```lua
function HPSMeterUI:OnShieldMitigated(result, targetName, hitValue)
    if result ~= ACTION_RESULT_DAMAGE_SHIELDED then return end
    local tName = zo_strformat("<<C:1>>", targetName)
    if not tName or tName == "" then return end
    if not HPSMeterUI:IsMyShieldActive(tName) then return end
    local amount = tonumber(hitValue) or 0
    if amount <= 0 then return end
    HPSMeterUI.overallMitigatedTotal = (HPSMeterUI.overallMitigatedTotal or 0) + amount
end
```
Crucially gated by `HPSMeterUI:IsMyShieldActive(tName)`:
```lua
function HPSMeterUI:IsMyShieldActive(name)
    local entry = self.myShieldedTargets[name]
    if not entry then return false end
    return (tonumber(entry.activeUntil) or 0) > GetGameTimeMilliseconds()
end
```
So a shielded hit only counts toward *your* mitigation total if the target is currently in your `myShieldedTargets` table **and** its `activeUntil` timestamp hasn't expired — preventing credit for someone else's shield absorbing damage on the same target.

### 11.2 Post-shield (unabsorbed) damage
```lua
EVENT_MANAGER:RegisterForEvent("HPSMeter_PostShieldDamage", EVENT_COMBAT_EVENT, function(...)
    local _, result, isError, _, _, _, _, _, targetName, _, hitValue = ...
    if isError then return end
    HPSMeterUI:OnPostShieldDamage(result, targetName, hitValue)
end)
EVENT_MANAGER:AddFilterForEvent("HPSMeter_PostShieldDamage", EVENT_COMBAT_EVENT,
    REGISTER_FILTER_COMBAT_RESULT, ACTION_RESULT_DAMAGE, ACTION_RESULT_CRITICAL_DAMAGE, ACTION_RESULT_BLOCKED_DAMAGE
)
```
Any real damage (`ACTION_RESULT_DAMAGE`), critical damage, or blocked damage landing on a currently-shielded target is tallied into `overallPostShieldDamageTotal` by `HPSMeterUI:OnPostShieldDamage`, which mirrors the same "must be my active shield target" gate as above (but checks specifically for `result == ACTION_RESULT_DAMAGE` before accumulating).

### 11.3 Turning the two totals into a percentage
```lua
function HPSMeterUI:GetMitigatedPercent()
    local mitigated = HPSMeterUI.overallMitigatedTotal or 0
    local post = HPSMeterUI.overallShieldingTotal or 0
    local total = mitigated + post
    if total <= 0 then return 0 end
    return (mitigated / total) * 100
end
```
> **Note**: The denominator here is `overallMitigatedTotal + overallShieldingTotal` (shielding output, not `overallPostShieldDamageTotal`/unabsorbed damage). This is the formula actually used for the displayed "Mitigated %" and the one saved into Battleground best-stats history — it effectively measures *mitigated damage relative to total shield output produced*, not relative to total incoming damage. `overallPostShieldDamageTotal` is tracked/accumulated by `OnPostShieldDamage` but is not currently read anywhere else in the file (a candidate for a future "damage prevented vs. damage leaked" display).

---

## 12. Step-by-Step: Rolling Windows ("Buckets") Explained

Both HPS and SPS use the same "bucket" pattern — an array with one slot per second of the configured window (default 10), where `buckets[1]` is the oldest second and `buckets[#buckets]` is the current second.

### `InitBuckets()` / `InitShieldBuckets()`
Fill the array with `window` zeros and record the current second as the window's start.

### `AdvanceBuckets(nowSec)` (and its shield twin `AdvanceShieldBuckets`)
```lua
function HPSMeterUI:AdvanceBuckets(nowSec)
    if (HPSMeterUI.bucketStartSec or 0) == 0 then
        HPSMeterUI.bucketStartSec = nowSec
        return
    end
    local diff = nowSec - HPSMeterUI.bucketStartSec
    if diff <= 0 then return end
    for _ = 1, math.min(diff, HPSMeterUI.saved.window) do
        local dropped = table.remove(HPSMeterUI.buckets, 1)
        HPSMeterUI.bucketTotal = HPSMeterUI.bucketTotal - (dropped or 0)
        table.insert(HPSMeterUI.buckets, 0)
    end
    HPSMeterUI.bucketStartSec = nowSec
end
```
Every time this runs, it figures out how many whole seconds (`diff`) have passed since the last time the window advanced. For each elapsed second (capped at `window`, so a long AFK gap doesn't loop excessively), it:
1. Removes the oldest bucket (`table.remove(..., 1)`) and subtracts its value from the running total — this is how old healing "falls out" of the average over time.
2. Appends a fresh `0` bucket at the end, ready to receive new healing this second.

This gives a classic **sliding-window average**: `HPS = bucketTotal / window`. New heals land in the *last* bucket (`buckets[#buckets]`); after `window` seconds without any new healing, the total naturally decays to `0`.

This function is called from three places: every incoming heal/shield event (to make sure the window is up-to-date before adding the new amount), and the once-per-second `"HPSMeter_SPS_Tick"` timer (so the number keeps decaying even with zero events).

---

## 13. Step-by-Step: Rendering the Label Text (`UpdateDisplay`)

`HPSMeterUI:UpdateDisplay()` is the single function that turns all the raw counters into the multi-line colored string shown on screen. Called after every heal, every shield delta, and once per second from the tick timer.

1. **Bail out** if `labelControl` doesn't exist yet (addon not fully initialized).
2. **Advance both rolling windows** to "now" so the numbers reflect decay even if called outside a combat event.
3. **Compute `hps` and `sps`** as `bucketTotal / window` and `shieldBucketTotal / shieldWindow` respectively.
4. **Line 1 (always shown)**: `HPS: <n>` and `SPS: <n>`, colored using `saved.labelColor` and `saved.shieldColor`, each run through `FormatShortNumber`.
5. **Line 2 (only if non-zero)**: `Heal Group: <n>` and/or `Shield Group: <n>` — cumulative totals applied to others, omitted entirely if both are zero (so the label doesn't show a permanent empty line before you've healed anyone else).
6. **Line 3 (only if non-zero)**: `Heal Personal: <n>` and/or `Shield Personal: <n>` — same idea for self-heals/shields.
7. **Mitigated line** — appended only if both `showShields` and `showLabel` are enabled: `Mitigated: <pct>%` from `GetMitigatedPercent()`.
8. **Overall line** — appended only if both `showOverall` and `showLabel` are enabled:
   ```lua
   local overallHPS = overallHealingTotal / max(1, (now - firstHealTime)/1000)
   local overallSPS = overallShieldingTotal / max(1, GetElapsedShieldSeconds())
   ```
   These divide the *lifetime* totals by the *actual elapsed time* since the first heal/shield this session (not the rolling window), giving a true session-long average rather than a moving one.
9. Passes the fully-assembled multi-line string (using `\r\n` as the line separator, and ESO's `|cRRGGBB...|r` inline color-code syntax per segment) to `HPSMeterUI:SetHealingLabelText(text)`, which writes it to both the visible label and its shadow twin.

### Convenience wrappers
`GetHPS()` and `GetShieldSPS()` both simply call `UpdateDisplay()` and then return the current `hps`/`sps` numeric value — used by settings-menu callbacks (e.g. changing a color) to force an immediate re-render using the new setting, while also handing back a value if a caller needs the current rate.

---

## 14. Step-by-Step: Resetting & Idle Auto-Reset

### Manual reset — `HPSMeterUI:Reset()`
Called by the "Reset Bloom HPS Data" settings button, and internally before each Battleground-stats save. It:
1. Calls `SavePreviousBGStats()` first (so you never lose a completed run's numbers just because the meter reset).
2. Zeroes every running total (`bucketTotal`, `shieldBucketTotal`, `overallHealingTotal`, `overallShieldingTotal`, personal/group splits, mitigation totals).
3. Resets `bucketStartSec` / `shieldBucketStartSec` to `0` (so the next heal/shield re-initializes the window fresh) and calls `InitBuckets()` / `InitShieldBuckets()`.
4. Clears `myShieldedTargets` (so stale shield tracking doesn't bleed into the new session).
5. Immediately writes a clean `"HPS: 0  SPS: 0"` string to the label.

### Automatic idle reset
```lua
EVENT_MANAGER:RegisterForUpdate("HPSMeterIdleReset", 1000, function()
    if HPSMeterUI.lastHealTime == 0 then return end
    if GetGameTimeMilliseconds() - HPSMeterUI.lastHealTime > (HPSMeterUI.saved.resetTimer or 300) * 1000 then
        HPSMeterUI:Reset()
        HPSMeterUI.lastHealTime = 0
        HPSMeterUI.firstHealTime = 0
        HPSMeterUI.alliedHP = 0
        HPSMeterUI.bucketTotal = 0
        HPSMeterUI.lastAlliedHealTick = 0
    end
end)
```
Every second, this checks how long it's been since your last heal landed. If that exceeds the configurable `resetTimer` (default 300 seconds / 5 minutes, adjustable 1–900s in the settings menu), the meter auto-resets — this prevents an idle player's "Overall HPS" from drifting down toward zero forever by averaging in long stretches of inactivity, and effectively starts a fresh "session" every time you've been out of combat for that long.

### Battleground-end reset
```lua
EVENT_MANAGER:RegisterForEvent("HPSMeter_Dataset", EVENT_BATTLEGROUND_STATE_CHANGED, function(ec, prevState, newState)
    if newState == BATTLEGROUND_STATE_FINISHED or newState == BATTLEGROUND_STATE_POSTGAME then
        HPSMeterUI:SavePreviousBGStats()
        ...
        HPSMeterUI:Reset()
    end
end)
```
When a Battleground match concludes, stats are archived (see next section) and the live meter resets for the next match.

---

## 15. Step-by-Step: Battleground Best-Stats History

### `SavePreviousBGStats()`
Snapshots the *current* session's `overallHealingTotal`, `overallShieldingTotal`, and `GetMitigatedPercent()` result, then:
- Updates the all-time high-water marks: `saved.topHealing`, `saved.topShielding`, `saved.topMitigation` (each is `math.max(old, new)`).
- Appends a dated entry (`{ healing, shielding, mitigation, timestamp }`, timestamp via `GetDateStringFromTimestamp(GetTimeStamp())`) to `saved.bgHistory`.
- Trims `bgHistory` to the most recent **20 entries** (`while #bgHistory > 20 do table.remove(bgHistory, 1) end`), so the SavedVariables file doesn't grow unbounded.

### `GetSavedBGMaxStats()`
Returns the all-time maximums, computed as the larger of the stored `topHealing/topShielding/topMitigation` fields **and** whatever the loop over `bgHistory` finds — a safety net in case the running top-fields and the history array ever disagree (e.g., after a manual edit or an old save format).

### `PrintSavedBGStats()`
Formats those maximums into one chat line, e.g.:
```
Bloom HPS Best Stats | Healing: 12.4m | Shielding: 3.1m | Mitigation: 42.7% | Entries: 20
```
Printed via `CHAT_ROUTER:AddSystemMessage(msg)` on console (where `d()`/chat input work differently) or `d(msg)` on PC.

### `ResetSavedBGStats()`
Zeros `topHealing`/`topShielding`/`topMitigation` and empties `bgHistory` — a destructive, permanent action (the settings-menu button for this has a `warning` string warning the user).

---

## 16. Step-by-Step: Settings Menu (LibAddonMenu-2.0)

`HPSMeterUI:CreateLAM()` builds the entire options panel. It re-reads the global `LibAddonMenu2` at call time (`LAM = LibAddonMenu2`) rather than trusting the module-load-time capture, specifically to avoid grabbing a stale/incomplete reference if LibAddonMenu finishes its own initialization slightly after this file is parsed. If the library isn't present, the function silently returns (`if not LAM or not LAM.RegisterAddonPanel then return end`) — this is what makes `LibAddonMenu-2.0` effectively required (declared in `## DependsOn:`) without hard-crashing if it's somehow missing.

It registers one panel, **"Bloom HPS"**, containing (in order):

| Control | Effect |
|---|---|
| Button — *Reset Bloom HPS Data* | Calls `HPSMeterUI:Reset()`. Has a confirmation `warning` string. |
| Button — *Reset Bloom HPS BG Stats* | Calls `HPSMeterUI:ResetSavedBGStats()`. Also warned. |
| Button — *Bloom HPS Help Data* | Calls `HPSMeterUI:GetHelp()` (prints the slash-command list — see note below). |
| **Header: Healing per second** | |
| Checkbox — *Show Healing Label* | Toggles `saved.showLabel` and shows/hides the main label, its shadow, the heart icon, and (if `showOverall` is also true) the overall label/icon; re-runs `RefreshWardenThemeLayout()`. |
| Slider — *Healing Label X* (0–2000) | Updates `saved.labelX` and re-anchors `labelControl` live. |
| Slider — *Healing Label Y* (0–2000) | Same, for Y. |
| Slider — *Healing Label Scale* (0.01–10.0) | Updates `saved.scale`, rescales the label/shadow/icon/overall-label/overall-icon, recomputes font size, and calls `GetHPS()` to force a redraw. |
| Editbox — *Healing Color* | Sets `saved.labelColor` (6-digit hex string), redraws via `GetHPS()`. |
| **Header: Shielding per second** | |
| Checkbox — *Show Shield per second* | Toggles `saved.showShields` (note: because of the Section 8 consolidation, this mainly affects whether the Mitigated-% line appears and whether shield deltas are tracked at all — the standalone shield control stays hidden either way). |
| Slider — *Shield per second label X/Y* (0–2000 each) | Updates `saved.shieldLabelx`/`shieldLabely` and re-anchors `shieldControl`. |
| Slider — *Shield per second label scale* (0.01–10.0) | Updates `saved.shieldScale`, rescales the shield controls, redraws via `GetShieldSPS()`. |
| Editbox — *Shielding Color* | Sets `saved.shieldColor`, redraws via `GetShieldSPS()`. |
| **Header: Overall** | |
| Checkbox — *Show Overall* | Toggles `saved.showOverall`, triggers both `GetHPS()` and `GetShieldSPS()` plus a layout refresh. |
| Editbox — *Overall Color* | Sets `saved.overallColor` (note: this setting is currently stored but the Overall line in `UpdateDisplay` actually reuses `labelColor`/`shieldColor` per metric rather than `overallColor` — a known minor inconsistency to be aware of if extending the code). |
| **Header: Reset Timer** | |
| Slider — *Idle Reset Timer (seconds)* (1–900, default 300) | Sets `saved.resetTimer`, directly consumed by the idle-reset timer in Section 14. |

> **Note on `GetHelp()`**: The settings button calls `HPSMeterUI:GetHelp()`, but the function actually defined in the file is named `HPSMeterUI:PrintHelp()` (see [Section 17](#17-step-by-step-slash-commands)). Since `GetHelp` is never defined anywhere, clicking that button will throw a "method does not exist" Lua error — this is a latent bug to fix by either renaming `PrintHelp` to `GetHelp` or changing the button's `func` to call `PrintHelp`.

---

## 17. Step-by-Step: Slash Commands

Registered inside `OnAddOnLoaded` via the `SLASH_COMMANDS` table (ESO's chat-command registry):

| Command | Calls | Effect |
|---|---|---|
| `/bloomhpslink` | `HPSMeterUI:LinkHealingData()` | Builds one long status string (overall healing, personal/group healing, current HPS, mitigated total/%, overall/personal/group shielding, lifetime SPS) and either opens chat input pre-filled with it (PC, via `StartChatInput`) or posts it as a system message (console, via `CHAT_ROUTER:AddSystemMessage`, since `StartChatInput` isn't available on Xbox/PlayStation). |
| `/bloomhpsstats` | `HPSMeterUI:PrintSavedBGStats()` | Prints the all-time best Battleground stats. |
| `/bloomhpsbg` | `HPSMeterUI:PrintSavedBGStats()` | Alias of the above. |
| `/bloomhpsmax` | `HPSMeterUI:PrintSavedBGStats()` | Alias of the above. |
| `/bloomhpsbest` | `HPSMeterUI:PrintSavedBGStats()` | Alias of the above. |
| `/bloomhpsresetstats` | `HPSMeterUI:ResetSavedBGStats()` | Wipes the saved Battleground history/records. |
| `/bloomhpsclear` | `HPSMeterUI:ResetSavedBGStats()` | Alias of the above. |

`HPSMeterUI:PrintHelp()` (intended to be reachable from the settings button, see the note in Section 16) simply `d()`-prints this same list of commands with one-line descriptions to local chat.

---

## 18. Enemy/Allied HP Tracking (`OnPowerUpdate`) — Experimental Stub

```lua
local function OnPowerUpdate(eventCode, tag, powerIndex, powerType, powerValue, powerMax, powerEMax)
    local name = GetUnitDisplayName(tag)
    if IsUnitAttackable(tag) then
        HPSMeterUI.enemyHP[name] = powerValue
    else
        HPSMeterUI.alliedHP[name] = powerValue
    end
    ...
end
```
This function is **defined but never registered** with `EVENT_MANAGER:RegisterForEvent(...)` anywhere in the current file — it exists in the source but is effectively dead code under the current build (no live event feeds it). Reading through its logic:
- It tries to distinguish enemy units (`IsUnitAttackable(tag)`) from allied/group units (`IsUnitSoloOrGroupLeader(tag)` / `IsUnitGrouped(tag)`), tracking each side's health in `enemyHP` / `alliedHP`.
- On the enemy branch, if health went *up* (healed) it updates `lastEnemyHealTick` and calls `HPSMeterUI:GetEnemyHPS()`.
- `GetEnemyHPS()` itself is a one-line stub: `function HPSMeterUI:GetEnemyHPS() return 0 end` — explicitly documented in-code as *"enemy HPS is tracked via OnPowerUpdate but display is not implemented."*
- There's also a latent bug if this were wired up: `HPSMeterUI.alliedHP` is initialized as the **number** `0` at file scope (`HPSMeterUI.alliedHP = 0`), but `OnPowerUpdate` treats it as a **table** (`HPSMeterUI.alliedHP[name] = powerValue`), which would error (`attempt to index a number value`) the moment it ran, since Lua cannot use `[]` indexing on a plain number.

This section exists in the README purely for completeness/transparency: **if you see `enemyHP`, `alliedHP`, `OnPowerUpdate`, or `GetEnemyHPS` in the source and wonder what they do, they are inert groundwork for a future "enemy healing" feature, not something currently affecting the displayed meter.**

---

## 19. SavedVariables Explained

The manifest declares `## SavedVariables: HPSMeterSavedVars HPSMeterHealingData`.

- **`HPSMeterSavedVars`** — the one actually used, created via `ZO_SavedVars:NewAccountWide("HPSMeterSavedVars", 2, nil, HPSMeterUI.defaults)`. "Account-wide" means these settings are shared across **every character on the account** on that platform/server, not per-character. This is the table behind `HPSMeterUI.saved`, holding:
  - All display settings (position, scale, colors, show/hide toggles) from `HPSMeterUI.defaults`.
  - `resetTimer` (idle auto-reset seconds).
  - `topHealing`, `topShielding`, `topMitigation`, `bgHistory[]` (the Battleground best-stats archive from Section 15).
  - `themeVersion` (added dynamically the first time `OnAddOnLoaded` runs the color migration, not present in `defaults`).
- **`HPSMeterHealingData`** — declared in the manifest (whitelisting it for persistence) but **never referenced anywhere in `HPSMeter.lua`**. It is reserved/unused — likely scaffolding for a future feature (e.g. a separate combat-log export) that hasn't been implemented yet.

These files live on disk under your ESO `SavedVariables` folder, e.g. `Documents\Elder Scrolls Online\live\SavedVariables\HPSMeter.lua`, and are only written when you log out or the client saves state — not in real time.

---

## 20. Textures

| File | Used by | Purpose |
|---|---|---|
| `textures/heart.dds` | `HPSMeterHealerIcon`, `HPSMeterHealerIconOverall` | Small heart icon next to the HPS/Overall-HPS text, visually tagging "this number is healing." |
| `textures/shield.dds` | `HPSMeterFlowerIcon` | Small shield icon next to the (currently hidden, see Section 8) standalone SPS label; conceptually tags "this number is shielding." |

Both are referenced by the in-addon virtual path `AmIHealing/textures/<file>.dds`, which matches the folder name on disk (`AmIHealing/`) — ESO resolves texture paths relative to the `AddOns` (or in this case `AddOnsManaged`) root, not the `.lua` file's own folder name, which is why the path is prefixed with the addon's folder name explicitly.

---

## 21. Known Limitations & Stubs

For transparency, here is an explicit list of things in the code that are either intentionally simplified or appear to be incomplete/buggy, discovered while documenting the above:

1. **`HPSMeterUI:IsPvP()` always returns `true`** — vestigial; not meaningfully branched on elsewhere.
2. **Enemy HPS is not implemented** — `GetEnemyHPS()` always returns `0`; `OnPowerUpdate` is defined but never registered to any event.
3. **`HPSMeterUI.alliedHP` type mismatch** — initialized as a number (`0`) but treated as a table inside the (currently-unused) `OnPowerUpdate`; would error if that function were wired up without first fixing this.
4. **Settings button "Bloom HPS Help Data" calls `HPSMeterUI:GetHelp()`**, but the implemented function is named `HPSMeterUI:PrintHelp()` — clicking that button will raise a Lua error until one of the two names is corrected.
5. **`saved.overallColor`** is configurable in the settings menu but the "Overall" line of the label currently reuses `labelColor`/`shieldColor` rather than `overallColor`.
6. **Turning off "Show Healing Label" (`showLabel`) also stops `GetHealing` from accumulating any totals at all** (it has an early `return` on `not saved.showLabel`), meaning Overall/session totals silently stop growing while the label is hidden, rather than merely not being displayed.
7. **`overallPostShieldDamageTotal`** is accumulated by `OnPostShieldDamage` but not currently consumed by any display/formula — tracked for a potential future "damage prevented vs. leaked" metric.
8. **Title/flower decorative labels** (`HPSMeterTitleLabel`, `HPSMeterFlowerTop`, `HPSMeterFlowerBottom`) are created and laid out but never given text content in the current version.

None of these prevent the addon from working as a functional personal HPS/SPS meter — they are documented here so future maintenance work starts from an accurate understanding of the code rather than re-discovering the same issues.

---

## 22. Installation

1. Copy the `AmIHealing` folder into your ESO AddOns directory:
   - **PC**: `Documents\Elder Scrolls Online\live\AddOns\`
   - **In-game (this environment)**: `...\AddOnsManaged\` (managed/cached AddOns path used by this client).
2. Ensure **LibAddonMenu-2.0** is also installed in the same AddOns directory (hard dependency — the addon's combat tracking still works without it, but the settings panel will not appear and `CreateLAM()` silently no-ops).
3. Launch ESO, and at the character-select or in-game Addons list, enable **"Bloom HPS"**.
4. In-game, open **Settings → Addons → Bloom HPS** to position, scale, and recolor the meter, or type `/bloomhpslink` / `/bloomhpsstats` in chat to verify it's working.

---

## 23. Quick Function Reference Table

| Function | Role |
|---|---|
| `HPSMeterUI:IsPvP()` | Stub, always `true`. |
| `FormatShortNumber(n)` | Number → `"1.5k"`/`"2.3m"`/`"1b"` style string. |
| `HexToRGBA(hex, alpha)` | `"rrggbb"` hex → `r,g,b,a` floats (0–1). |
| `StripESOColorCodes(text)` | Pass-through seam for shadow-text color stripping. |
| `HPSMeterUI:SetHealingLabelText/SetShieldLabelText/SetHealingOverallText` | Write text to a label + its shadow twin. |
| `HPSMeterUI:RefreshWardenThemeLayout()` | Resize/reposition the backdrop panel to fit current text/scale. |
| `HPSMeterUI:Reset()` | Zero all live counters; archive previous stats first. |
| `HPSMeterUI:GetMitigatedPercent()` | `mitigated / (mitigated + shieldingOutput) * 100`. |
| `HPSMeterUI:GetSavedBGMaxStats()` | All-time max healing/shielding/mitigation across history + top fields. |
| `HPSMeterUI:SavePreviousBGStats()` | Archive current session into `bgHistory` (max 20 entries) + update top fields. |
| `HPSMeterUI:PrintSavedBGStats()` | Chat-print the all-time bests. |
| `HPSMeterUI:ResetSavedBGStats()` | Wipe all-time bests + history. |
| `HPSMeterUI:GetElapsedShieldSeconds()` / `:GetAvgShieldPS()` | Lifetime shield timing helpers. |
| `HPSMeterUI:CreateUI()` | Build every on-screen control once, at load time. |
| `HPSMeterUI:LinkHealingData()` | Compose + post a full stats summary string to chat. |
| `HPSMeterUI:InitBuckets()` / `:AdvanceBuckets(nowSec)` | HPS rolling-window lifecycle. |
| `HPSMeterUI:InitShieldBuckets()` / `:AdvanceShieldBuckets(nowSec)` | SPS rolling-window lifecycle. |
| `HPSMeterUI:UpdateDisplay()` | Recompute HPS/SPS/mitigated%/overall and render the label text. |
| `HPSMeterUI:GetHPS()` / `:GetShieldSPS()` | Force a redraw, return current rate. |
| `HPSMeterUI:IsMyShieldActive(name)` | Is `name` currently within an active shield window you applied? |
| `HPSMeterUI:OnShieldMitigated(result, targetName, hitValue)` | Add absorbed-damage amount to mitigation total (gated by `IsMyShieldActive`). |
| `HPSMeterUI:OnPostShieldDamage(result, targetName, hitValue)` | Add unabsorbed damage to the post-shield total (gated likewise). |
| `HPSMeterUI:GetShielding(result, targetName)` | Mark a target as "shielded by me" for 20s after a gained-effect combat event. |
| `HPSMeterUI:GetLifetimeShieldPS()` | `overallShieldingTotal / elapsed seconds since first shield`. |
| `HPSMeterUI:GetEnemyHPS()` | Stub, always `0`. |
| `HPSMeterUI:UpdateShieldVisuals(unitTag, newShieldValue)` | Core shield-delta tracker driven by `EVENT_UNIT_ATTRIBUTE_VISUAL_*`. |
| `GetHealing(...)` (global) | `EVENT_COMBAT_EVENT` handler for player-sourced heals; feeds the HPS pipeline. |
| `HPSMeterUI:CreateLAM()` | Build the LibAddonMenu-2.0 settings panel. |
| `OnPowerUpdate(...)` (local, unused) | Experimental/dead-code enemy & ally HP tracker. |
| `HPSMeterUI:PrintHelp()` | Chat-print the list of slash commands. |
| `OnAddOnLoaded(event, addonName)` (local) | Entry point: load settings, build UI, register all events/timers/commands. |

---

*This README documents the addon as implemented in `HPSMeter.lua` (AddOnVersion 2.1). If the code changes, re-derive this document from the source rather than editing it independently, to keep it accurate.*
