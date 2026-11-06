-- ============================================================================
-- Bloom HPS - Data
-- The only file that talks to LibFights. Everything else asks this module for
-- the four numbers, so a LibFights API change only needs fixing here.
-- ============================================================================

local M = HPSMeterUI
local Data = {}
M.Data = Data

local ZERO = { hps = 0, hpm = 0, sps = 0, spm = 0, shieldTotal = 0, active = false, hasFight = false }

-- The running fight, or the last finished one so the meter keeps showing the
-- result after combat ends.
function Data.GetFight()
    return LibFights.GetLastFight()
end

-- Returns { hps, hpm, sps, spm, shieldTotal, active, hasFight }.
--   hps / hpm   : effective healing you did (overheal excluded), per second / minute
--   sps / spm   : damage absorbed by shields on you, per second / minute
--   shieldTotal : total damage absorbed by shields on you this fight
-- All values come straight from LibFights' fight methods; rates are averaged
-- over the whole fight duration.
function Data.GetStats()
    local fight = Data.GetFight()
    if not fight then return ZERO end

    return {
        hps = fight:GetHPS(),
        hpm = fight:GetHPM(),
        sps = fight:GetSPS(),
        spm = fight:GetSPM(),
        shieldTotal = fight:GetTotalShield(),
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
