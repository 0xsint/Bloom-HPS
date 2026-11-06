--[[
    LibFights - HUD
    Optional small live meter (DPS / HPS / DTPS / MPS / crit / APM). Built in Lua (no XML)
    and added to the HUD scenes, so it works with keyboard and gamepad UI on PC and console.
    Showing the HUD never starts logging by itself.
]]

local LF = LibFights
local HUD = {}
LF.HUD = HUD

local UPDATE_NS = "LibFights_HUD"

local function S() return LF.GetSettings() end

function HUD.Create()
    if HUD.window then return HUD.window end
    local wm = WINDOW_MANAGER
    local gamepad = LF.IsGamepad()
    local win = wm:CreateTopLevelWindow("LibFightsHUD")
    win:SetDimensions(gamepad and 280 or 230, gamepad and 130 or 100)
    win:SetClampedToScreen(true)
    win:SetMouseEnabled(not LF.isConsole)
    win:SetMovable(not LF.isConsole and not S().hudLocked)
    win:ClearAnchors()
    win:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, S().hudX or 60, S().hudY or 320)
    win:SetHandler("OnMoveStop", function(self)
        S().hudX, S().hudY = self:GetLeft(), self:GetTop()
    end)

    local bg = wm:CreateControl("$(parent)BG", win, CT_BACKDROP)
    bg:SetAnchorFill()
    bg:SetCenterColor(0, 0, 0, 0.55)
    bg:SetEdgeColor(0.4, 0.6, 0.9, 0.6)
    pcall(bg.SetEdgeTexture, bg, "", 1, 1, 1)

    local label = wm:CreateControl("$(parent)Text", win, CT_LABEL)
    label:SetFont(gamepad and "ZoFontGamepad22" or "ZoFontGameSmall")
    label:SetColor(1, 1, 1, 1)
    label:SetAnchor(TOPLEFT, win, TOPLEFT, 8, 6)
    label:SetAnchor(BOTTOMRIGHT, win, BOTTOMRIGHT, -8, -6)
    label:SetText("LibFights")

    HUD.window, HUD.label = win, label
    if ZO_HUDFadeSceneFragment then
        HUD.fragment = ZO_HUDFadeSceneFragment:New(win)
    elseif ZO_SimpleSceneFragment then
        HUD.fragment = ZO_SimpleSceneFragment:New(win)
    end
    win:SetHidden(true)
    return win
end

function HUD.Update()
    if not HUD.label then return end
    local f = LF.Logger.GetLastFight()
    local text = LF.Report.ShortLiveText(f)
    if not LF.Logger.IsLogging() then text = text .. "\n|cFF8080not logging|r" end
    HUD.label:SetText(text)
end

function HUD.Show()
    HUD.Create()
    if HUD.fragment and not HUD.fragmentAdded then
        if HUD_SCENE then HUD_SCENE:AddFragment(HUD.fragment) end
        if HUD_UI_SCENE then HUD_UI_SCENE:AddFragment(HUD.fragment) end
        HUD.fragmentAdded = true
    end
    if not HUD.fragment then HUD.window:SetHidden(false) end
    EVENT_MANAGER:RegisterForUpdate(UPDATE_NS, 500, HUD.Update)
    HUD.Update()
end

function HUD.Hide()
    EVENT_MANAGER:UnregisterForUpdate(UPDATE_NS)
    if HUD.fragment and HUD.fragmentAdded then
        if HUD_SCENE then HUD_SCENE:RemoveFragment(HUD.fragment) end
        if HUD_UI_SCENE then HUD_UI_SCENE:RemoveFragment(HUD.fragment) end
        HUD.fragmentAdded = false
    end
    if HUD.window then HUD.window:SetHidden(true) end
end

function HUD.SetShown(shown)
    S().showHUD = shown and true or false
    if shown then HUD.Show() else HUD.Hide() end
end

function HUD.SetLocked(locked)
    S().hudLocked = locked and true or false
    if HUD.window then HUD.window:SetMovable(not LF.isConsole and not locked) end
end

function HUD.Init()
    if S().showHUD then HUD.Show() end
end
