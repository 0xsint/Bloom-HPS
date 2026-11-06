-- ============================================================================
-- Bloom HPS - UI
-- One text label with a drop shadow and a backdrop that sizes itself to fit.
-- ============================================================================

local M = HPSMeterUI
local UI = {}
M.UI = UI

local format, floor, max = string.format, math.floor, math.max
local Fmt = M.FormatShortNumber

local PAD_X, PAD_Y = 14, 10
local controls = {}

local function StripColorCodes(text)
    return (text:gsub("|c%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Colorize(hex, text)
    return format("|c%s%s|r", hex, text)
end

function UI.Create()
    local wm = WINDOW_MANAGER
    local root = wm:CreateTopLevelWindow("HPSMeterControl")
    root:SetMouseEnabled(false)
    root:SetAnchorFill(GuiRoot)

    local backdrop = wm:CreateControl("HPSMeterBackdrop", root, CT_BACKDROP)
    backdrop:SetCenterTexture("EsoUI/Art/Miscellaneous/white.dds")
    backdrop:SetEdgeTexture("EsoUI/Art/Miscellaneous/white.dds", 1, 1, 2)
    backdrop:SetInsets(0, 0, -1, -1)
    backdrop:SetCenterColor(M.HexToRGBA("132c1f", 0.72))
    backdrop:SetEdgeColor(M.HexToRGBA("8ecf9a", 0.95))
    backdrop:SetDrawLevel(0)

    local shadow = wm:CreateControl("HPSMeterLabelShadow", root, CT_LABEL)
    shadow:SetColor(0.05, 0.14, 0.08, 0.95)
    shadow:SetDrawLevel(1)

    local label = wm:CreateControl("HPSMeterLabel", root, CT_LABEL)
    label:SetDrawLevel(2)

    shadow:SetAnchor(TOPLEFT, label, TOPLEFT, 1, 1)
    backdrop:SetAnchor(TOPLEFT, label, TOPLEFT, -PAD_X, -PAD_Y)
    backdrop:SetAnchor(BOTTOMRIGHT, label, BOTTOMRIGHT, PAD_X, PAD_Y)

    controls.root, controls.backdrop = root, backdrop
    controls.label, controls.shadow = label, shadow

    UI.ApplyLayout()
end

-- Re-applies position, scale and visibility from the saved settings.
function UI.ApplyLayout()
    local saved, label = M.saved, controls.label
    if not label then return end

    local font = format("$(MEDIUM_FONT)|%d|outline", max(14, floor(22 * saved.scale)))
    for _, ctrl in ipairs({ label, controls.shadow }) do
        ctrl:SetFont(font)
        ctrl:SetScale(saved.scale)
    end

    label:ClearAnchors()
    label:SetAnchor(TOPLEFT, controls.root, TOPLEFT, saved.labelX, saved.labelY)

    local hidden = not saved.showLabel
    label:SetHidden(hidden)
    controls.shadow:SetHidden(hidden)
    controls.backdrop:SetHidden(hidden)

    UI.Refresh()
end

function UI.BuildText(stats)
    local saved = M.saved
    local lines = {}
    local function Add(color, text) lines[#lines + 1] = Colorize(color, text) end

    Add(saved.labelColor, format("HPS: %s  HPM: %s", Fmt(stats.hps), Fmt(stats.hpm)))
    if saved.showSplits then
        Add(saved.labelColor, format("Heal Personal: %s  Group: %s",
            Fmt(stats.healPersonal), Fmt(stats.healGroup)))
    end

    if saved.showShields then
        Add(saved.shieldColor, format("SPS: %s  SPM: %s  Shield: %s",
            Fmt(stats.sps), Fmt(stats.spm), Fmt(stats.shieldTotal)))
        if saved.showSplits then
            -- group shields are only recorded in LibFights group mode
            local group = stats.groupMode and Fmt(stats.shieldGroup) or "-"
            Add(saved.shieldColor, format("Shield Personal: %s  Group: %s",
                Fmt(stats.shieldPersonal), group))
        end
    end

    if saved.showMitigation then
        Add(saved.mitigationColor, format("Mitigated: %s  MPS: %s  (%.1f%%)",
            Fmt(stats.mitigated), Fmt(stats.mps), stats.mitigatedPct))
    end

    return table.concat(lines, "\n")
end

function UI.Refresh()
    if not controls.label or not M.saved.showLabel then return end
    local text = UI.BuildText(M.Data.GetStats())
    controls.label:SetText(text)
    controls.shadow:SetText(StripColorCodes(text))
end
