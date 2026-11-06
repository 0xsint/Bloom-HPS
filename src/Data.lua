-- ============================================================================
-- Bloom HPS - Data
-- The only file that talks to LibFights. Everything else asks this module for
-- the four numbers, so a LibFights API change only needs fixing here.
-- ============================================================================

local M = HPSMeterUI
local Data = {}
M.Data = Data

local ZERO = { hps = 0, hpm = 0, sps = 0, spm = 0, active = false, hasFight = false }

-- The running fight, or the last finished one so the meter keeps showing the
-- result after combat ends.
function Data.GetFight()
    return LibFights.GetLastFight()
end

-- Returns { hps, hpm, sps, spm, active, hasFight }.
--   hps / hpm : effective healing you did (overheal excluded), per second / minute
--   sps / spm : damage absorbed by shields on you, per second / minute
-- Rates are averaged over the whole fight duration.
function Data.GetStats()
    local fight = Data.GetFight()
    if not fight then return ZERO end

    local seconds = fight:GetDurationSec() -- always >= 1
    local hps = fight:GetHPS()
    local sps = (fight.totals.shieldAbsorbedIn or 0) / seconds

    return {
        hps = hps,
        hpm = hps * 60,
        sps = sps,
        spm = sps * 60,
        active = fight:IsActive(),
        hasFight = true,
    }
end

-- Asks LibFights to start logging (it records nothing until this is called).
-- Safe if another add-on already started it.
function Data.StartLogging()
    if LibFights.IsLogging() then return true end
    return LibFights.Start_Logging()
end
