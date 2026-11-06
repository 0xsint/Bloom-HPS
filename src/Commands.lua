-- ============================================================================
-- Bloom HPS - Slash commands
--   /bloomhps        print the current (or last) fight's numbers and shield total
--   /bloomhps help   list commands
-- ============================================================================

local M = HPSMeterUI
local Commands = {}
M.Commands = Commands

local format = string.format
local Fmt = M.FormatShortNumber

local function PrintStats()
    local stats = M.Data.GetStats()
    if not stats.hasFight then
        M.Print("No fight recorded yet.")
        return
    end
    M.Print(format("%s fight | HPS %s | HPM %s | SPS %s | SPM %s | Shield %s",
        stats.active and "Current" or "Last",
        Fmt(stats.hps), Fmt(stats.hpm), Fmt(stats.sps), Fmt(stats.spm), Fmt(stats.shieldTotal)))
end

local function PrintHelp()
    M.Print("/bloomhps - show HPS / HPM / SPS / SPM and shield total for the current or last fight")
    M.Print("/bloomhps help - show this list")
end

function Commands.Register()
    SLASH_COMMANDS["/bloomhps"] = function(args)
        if args and args:lower():match("^%s*help") then
            PrintHelp()
        else
            PrintStats()
        end
    end
end
