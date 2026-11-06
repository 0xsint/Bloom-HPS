-- ============================================================================
-- Bloom HPS - Settings
-- LibAddonMenu-2.0 panel (optional: the meter works without it).
-- ============================================================================

local M = HPSMeterUI
local Settings = {}
M.Settings = Settings

local function Relayout() M.UI.ApplyLayout() end

local function Bind(key, onChange)
    return function() return M.saved[key] end,
        function(value)
            M.saved[key] = value
            if onChange then onChange(value) end
        end
end

local function Checkbox(name, key)
    local getFunc, setFunc = Bind(key, Relayout)
    return { type = "checkbox", name = name, getFunc = getFunc, setFunc = setFunc, default = M.defaults[key] }
end

local function Slider(name, key, minValue, maxValue, step)
    local getFunc, setFunc = Bind(key, Relayout)
    return {
        type = "slider", name = name, min = minValue, max = maxValue, step = step,
        decimals = step < 1 and 2 or 0,
        getFunc = getFunc, setFunc = setFunc, default = M.defaults[key],
    }
end

local function Color(name, key, fallback)
    return {
        type = "editbox", name = name, tooltip = "6-digit hex color, e.g. " .. fallback,
        default = fallback,
        getFunc = function() return M.saved[key] end,
        setFunc = function(value)
            M.saved[key] = M.SanitizeHex(value, fallback)
            M.UI.Refresh()
        end,
    }
end

function Settings.Create()
    local LAM = LibAddonMenu2
    if not LAM or not LAM.RegisterAddonPanel then return end

    local panelName = M.name .. "Panel"
    LAM:RegisterAddonPanel(panelName, {
        type = "panel",
        name = M.title,
        displayName = M.title,
        author = M.author,
        version = M.version,
        registerForRefresh = true,
        registerForDefaults = true,
    })

    LAM:RegisterOptionControls(panelName, {
        { type = "header", name = "Display" },
        Checkbox("Show Meter", "showLabel"),
        Slider("Position X", "labelX", 0, 2000, 1),
        Slider("Position Y", "labelY", 0, 2000, 1),
        Slider("Scale", "scale", 0.1, 10, 0.05),

        { type = "header", name = "Healing" },
        Color("Healing Color", "labelColor", M.DEFAULT_HEAL_COLOR),

        { type = "header", name = "Shielding" },
        Checkbox("Show Shield Line (SPS / SPM / total)", "showShields"),
        Color("Shielding Color", "shieldColor", M.DEFAULT_SHIELD_COLOR),
    })
end
