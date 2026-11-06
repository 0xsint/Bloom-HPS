# Bloom HPS

An Elder Scrolls Online addon that shows your **Healing Per Second (HPS)** and **Shielding Per Second (SPS)**, tracks damage absorbed by your shields, and remembers your best Battleground runs. It works on **PC and console** and is safe to use in PvP.

## Features

The on-screen meter shows:

| Line | Contents |
|---|---|
| 1 | Rolling **HPS** and **SPS**, averaged over the last *N* seconds (default 10) |
| 2 | **Group** totals: healing and shielding you gave to other players |
| 3 | **Personal** totals: healing and shielding you gave to yourself |
| 4 | **Mitigated %**: damage absorbed by your shields ÷ (absorbed + shielding applied) |
| 5 | **Overall HPS / SPS**: average rates since the last reset |

Lines 2–3 appear once they are non-zero. Shielding and Overall lines can be turned off in the settings.

The meter resets on its own after a configurable idle time (default 5 minutes) and at the end of every Battleground. Each finished session is saved to a history of the last 20 runs, which also feeds your all-time best stats.

## Installation

1. Copy this folder into your ESO AddOns directory as **`HPSMeter`**. The folder name must match `HPSMeter.addon`.
   - PC: `Documents\Elder Scrolls Online\live\AddOns\HPSMeter\`
2. Install **LibAddonMenu-2.0**. The settings panel requires it.
3. Enable **Bloom HPS** in the in-game AddOns list.
4. Configure it under **Settings → Addons → Bloom HPS**.

## Slash commands

| Command | Action |
|---|---|
| `/bloomhps` | Show the command list |
| `/bloomhpslink` | Put a summary of the current session in the chat box, ready to send (PC); prints it on console |
| `/bloomhpsstats` | Show saved best stats (aliases: `/bloomhpsbg`, `/bloomhpsmax`, `/bloomhpsbest`) |
| `/bloomhpsreset` | Reset the current session (it is saved to history first) |
| `/bloomhpsresetstats` | Clear saved best stats and history (alias: `/bloomhpsclear`) |

## Settings

| Setting | Default | Notes |
|---|---|---|
| Show Meter | on | Hides the meter. Tracking continues while it is hidden. |
| Position X / Y | 300 / 200 | |
| Scale | 0.5 | |
| Rolling Window | 10 s | Applies to both HPS and SPS |
| Healing / Shielding / Overall color | `9ff8ba` / `b8f7ff` / `d6ffd6` | 6-digit hex values. Invalid input falls back to the default. |
| Show Shielding & Mitigation | on | Hides the SPS, shield and mitigation values |
| Show Overall HPS / SPS | on | |
| Idle Reset Timer | 300 s | Time without healing or shielding before the session resets |

Settings are saved account-wide in `SavedVariables/HPSMeter.lua`. Settings from earlier versions carry over.

## How it works

Everything is in `HPSMeter.lua`. The file is organised top to bottom as follows.

1. **Helpers**: number formatting (`1.5k`, `12m`), hex color handling, chat output, and a memoised name normaliser. Combat events report names as `Name^Mx`, while unit APIs report plain names.
2. **`RollingWindow`**: a ring buffer with one bucket per second. Adding a value or moving time forward is O(1). The rate is `total / windowSize`.
3. **Session state** (`HPSMeterUI.session`): totals, first-event timestamps, and the last activity time. `HPSMeterUI:Reset()` saves the session to history if it has any data, then starts a new one.
4. **Healing**: one `EVENT_COMBAT_EVENT` registration per heal result (heal, crit heal, HoT tick, crit HoT tick). Each one is filtered to the player as the source, so the game only calls the addon for your own heals. The target type decides whether a heal is personal or group.
5. **Shielding** works in three steps:
   - A buff you apply (`EFFECT_GAINED` / `EFFECT_GAINED_DURATION`, source = you) puts the target on a watch list for 20 seconds.
   - `EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED/UPDATED/REMOVED` reports the shield value on that unit. An **increase** counts as shielding you did. Entries are keyed by name, so one unit reported under several tags (`player` and `groupN`) is counted once.
   - `ACTION_RESULT_DAMAGE_SHIELDED` hits on a watched unit with an active shield add to the mitigated total.
6. **Display**: a single label with a drop-shadow copy and a backdrop that resizes to fit the text. Events only mark the display as dirty. A 500 ms tick redraws it when something changed or a second has passed. The same tick handles the idle reset and clears out expired shield entries.
7. **Settings**: a LibAddonMenu-2.0 panel. "Reset to defaults" works for every option.

## Known limitations

- The addon cannot tell which shield on a unit is yours. If a target you buffed also gets a shield from another player within the watch window, that shield counts toward your SPS.
- Heals from pets and companions are not counted. Only heals with the player as the source are.
- `textures/heart.dds` and `textures/shield.dds` are kept for future use. The current single-label layout does not use them.
