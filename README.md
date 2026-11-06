# Bloom HPS (LibFights edition)

A small Elder Scrolls Online meter that shows the following numbers, all taken from **LibFights**:

| Value | Meaning |
|---|---|
| **HPS** | Effective healing you did per second (overheal excluded) |
| **HPM** | The same per minute |
| **SPS** | Damage absorbed by shields on you per second |
| **SPM** | The same per minute |
| **Shield** | Total damage absorbed by shields on you this fight |

Rates are averaged over the current fight. When combat ends the meter keeps showing that fight's final numbers until the next fight starts. LibFights decides when fights start and end.

## Requirements

- **LibFights** 1.0.0 with the shield API (`GetSPS`, `GetSPM`, `GetTotalShield`) (required). A copy is in `LibFights/`.
- **LibAddonMenu-2.0** (optional, for the settings panel).

## Installation

1. Copy this folder into your AddOns directory as **`HPSMeter`**. The folder name must match `HPSMeter.addon`.
   - PC live: `Documents\Elder Scrolls Online\live\AddOns\HPSMeter\`
   - PTS: `Documents\Elder Scrolls Online\pts\AddOns\HPSMeter\`
2. Make sure LibFights is installed. The bundled `HPSMeter/LibFights/` copy works, or you can install it as its own `AddOns/LibFights/` folder. Use one copy, not both.
3. Enable **Bloom HPS** and **LibFights** in the in-game AddOns list.

Bloom HPS calls `Start_Logging()` for you when it loads. LibFights records nothing until that call. If another addon already started logging, Bloom HPS just reads the same data.

## Commands

| Command | Action |
|---|---|
| `/bloomhps` | Print HPS / HPM / SPS / SPM and the shield total for the current or last fight |
| `/bloomhps help` | List commands |

## Settings

Settings are under **Settings → Addons → Bloom HPS**: show/hide, position X/Y, scale, healing color, shielding color, and show/hide the shield line (SPS / SPM / total). Settings from earlier versions (position, colors) carry over.

## Code layout

| File | Responsibility |
|---|---|
| `HPSMeter.addon` | Manifest. Declares LibFights as a dependency and sets the load order. |
| `src/Core.lua` | Namespace, defaults, number/color helpers, chat output |
| `src/Data.lua` | **The only file that touches LibFights.** Turns the current fight into `{ hps, hpm, sps, spm, shieldTotal }`. |
| `src/UI.lua` | Label, shadow and auto-sizing backdrop. Builds the display text. |
| `src/Settings.lua` | LibAddonMenu-2.0 panel |
| `src/Commands.lua` | Slash commands |
| `src/Init.lua` | Startup. Hooks into LibFights' `FIGHT_STARTED` / `FIGHT_ENDED` callbacks. |

### Performance

Bloom HPS registers **no combat events of its own** and does not listen to LibFights' per-event `COMBAT_EVENT` callback. It reads the fight totals that LibFights already keeps, on a 500 ms timer that only runs during a fight. Out of combat it does nothing.

## How the numbers are calculated

From the LibFights fight object (`LibFights.GetLastFight()`):

| Value | LibFights call |
|---|---|
| HPS | `fight:GetHPS()` (`totals.healOut / duration`) |
| HPM | `fight:GetHPM()` |
| SPS | `fight:GetSPS()` (`GetTotalShield() / duration`) |
| SPM | `fight:GetSPM()` |
| Shield | `fight:GetTotalShield()` (`totals.shieldAbsorbedIn`) |

## Known limitations

- **SPS is shields absorbing damage on you, not shields you cast on others.** LibFights counts a "shield" when the game reports that damage was absorbed by a shield (`ACTION_RESULT_DAMAGE_SHIELDED`). That event says who was shielded, but not whose shield it was. As a result:
  - Shields from other players that absorb damage on you are counted.
  - Shields you put on allies are not.
- Heals from pets are counted, because LibFights treats player pets as the player. Heals from companions are not.
