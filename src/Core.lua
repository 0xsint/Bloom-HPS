-- ============================================================================
-- Bloom HPS - Core
-- Namespace, constants, saved-setting defaults and small shared helpers.
-- ============================================================================

HPSMeterUI = HPSMeterUI or {}
local M = HPSMeterUI

M.name    = "HPSMeter"
M.title   = "Bloom HPS"
M.version = "4.0"
M.author  = "Vixen Hunny"

M.TICK_MS = 500 -- how often the meter redraws while a fight is running

M.DEFAULT_HEAL_COLOR   = "9ff8ba"
M.DEFAULT_SHIELD_COLOR = "b8f7ff"

M.defaults = {
    showLabel   = true,
    labelX      = 300,
    labelY      = 200,
    scale       = 0.5,
    labelColor  = M.DEFAULT_HEAL_COLOR,
    showShields = true,
    shieldColor = M.DEFAULT_SHIELD_COLOR,
}

local floor, format = math.floor, string.format

-- 950 -> "950", 1500 -> "1.5k", 12000 -> "12k", 2300000 -> "2.3m"
function M.FormatShortNumber(n)
    n = tonumber(n) or 0
    local absN = math.abs(n)
    local divisor, suffix
    if absN >= 1e9 then
        divisor, suffix = 1e9, "b"
    elseif absN >= 1e6 then
        divisor, suffix = 1e6, "m"
    elseif absN >= 1e3 then
        divisor, suffix = 1e3, "k"
    else
        return tostring(floor(n))
    end
    local v = n / divisor
    if absN >= divisor * 10 then
        return format("%.0f%s", v, suffix)
    end
    return (format("%.1f", v):gsub("%.0$", "")) .. suffix
end

-- Returns a clean lowercase 6-digit hex string, or the fallback if invalid.
function M.SanitizeHex(value, fallback)
    local hex = tostring(value or ""):gsub("^#", ""):lower()
    if hex:match("^%x%x%x%x%x%x$") then return hex end
    return fallback
end

function M.HexToRGBA(hex, alpha)
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255, alpha or 1
end

function M.Print(msg)
    msg = format("[%s] %s", M.title, msg)
    if IsConsoleUI() and CHAT_ROUTER then
        CHAT_ROUTER:AddSystemMessage(msg)
    else
        d(msg)
    end
end
