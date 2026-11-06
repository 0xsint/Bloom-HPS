-- ============================================================================
-- Bloom HPS - Healing / Shielding per second meter (PC & Console, PvP safe)
-- ============================================================================

local ADDON_NAME    = "HPSMeter"
local ADDON_TITLE   = "Bloom HPS"
local ADDON_VERSION = "3.0"
local ADDON_AUTHOR  = "Vixen Hunny"

HPSMeterUI = HPSMeterUI or {}
local M = HPSMeterUI

local floor, max = math.floor, math.max
local format = string.format

-- ----------------------------------------------------------------------------
-- Constants
-- ----------------------------------------------------------------------------
local TICK_MS              = 500    -- display / housekeeping tick
local SHIELD_APPLY_WAIT_MS = 20000  -- how long a buffed target is watched for a shield value
local SHIELD_STALE_MS      = 30000  -- give up on a shield that stopped reporting updates
local SHIELD_DROP_GRACE_MS = 1500   -- keep counting absorbs briefly after a shield hits 0
local MAX_BG_HISTORY       = 20
local NAME_CACHE_LIMIT     = 500

local DEFAULT_HEAL_COLOR    = "9ff8ba"
local DEFAULT_SHIELD_COLOR  = "b8f7ff"
local DEFAULT_OVERALL_COLOR = "d6ffd6"

M.defaults = {
    showLabel    = true,
    labelX       = 300,
    labelY       = 200,
    window       = 10,
    shieldWindow = 10,
    scale        = 0.5,
    labelColor   = DEFAULT_HEAL_COLOR,
    showShields  = true,
    shieldColor  = DEFAULT_SHIELD_COLOR,
    showOverall  = true,
    overallColor = DEFAULT_OVERALL_COLOR,
    resetTimer   = 300,
    topHealing   = 0,
    topShielding = 0,
    topMitigation = 0,
    bgHistory    = {},
}

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------
local function FormatShortNumber(n)
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

local function HexToRGBA(hex, alpha)
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255, alpha or 1
end

-- Returns a clean lowercase 6-digit hex string, or the fallback if invalid.
local function SanitizeHex(value, fallback)
    local hex = tostring(value or ""):gsub("^#", ""):lower()
    if hex:match("^%x%x%x%x%x%x$") then return hex end
    return fallback
end

local function StripColorCodes(text)
    return (text:gsub("|c%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Colorize(hex, text)
    return format("|c%s%s|r", hex, text)
end

local function Print(msg)
    msg = format("[%s] %s", ADDON_TITLE, msg)
    if IsConsoleUI() and CHAT_ROUTER then
        CHAT_ROUTER:AddSystemMessage(msg)
    else
        d(msg)
    end
end

-- Combat events report names like "Name^Mx"; unit APIs report raw names.
-- Normalise both the same way, memoised because this runs in combat.
local nameCache, nameCacheSize = {}, 0
local function CleanName(raw)
    if not raw or raw == "" then return nil end
    local clean = nameCache[raw]
    if clean == nil then
        clean = zo_strformat("<<C:1>>", raw)
        if clean == "" then clean = false end
        if nameCacheSize >= NAME_CACHE_LIMIT then
            nameCache, nameCacheSize = {}, 0
        end
        nameCache[raw] = clean
        nameCacheSize = nameCacheSize + 1
    end
    return clean or nil
end

-- ----------------------------------------------------------------------------
-- Rolling window: one bucket per second, ring buffer, O(1) per update.
-- ----------------------------------------------------------------------------
local RollingWindow = {}
RollingWindow.__index = RollingWindow

function RollingWindow:New(size)
    local window = setmetatable({}, self)
    window:Resize(size)
    return window
end

function RollingWindow:Resize(size)
    self.size = max(1, floor(tonumber(size) or 10))
    self:Clear()
end

function RollingWindow:Clear()
    self.buckets = {}
    for i = 1, self.size do self.buckets[i] = 0 end
    self.head = 1
    self.total = 0
    self.second = nil
end

function RollingWindow:Advance(nowSec)
    local last = self.second
    self.second = nowSec
    if not last then return end

    local elapsed = nowSec - last
    if elapsed <= 0 then return end

    local buckets, size = self.buckets, self.size
    if elapsed >= size then
        for i = 1, size do buckets[i] = 0 end
        self.total = 0
        return
    end

    local head = self.head
    for _ = 1, elapsed do
        head = head % size + 1
        self.total = self.total - buckets[head]
        buckets[head] = 0
    end
    self.head = head
end

function RollingWindow:Add(nowSec, amount)
    self:Advance(nowSec)
    self.buckets[self.head] = self.buckets[self.head] + amount
    self.total = self.total + amount
end

function RollingWindow:GetRate()
    return self.total / self.size
end

-- ----------------------------------------------------------------------------
-- Session state (everything that resets between fights / battlegrounds)
-- ----------------------------------------------------------------------------
local function NewSession()
    return {
        healTotal      = 0,
        personalHeal   = 0,
        groupHeal      = 0,
        shieldTotal    = 0,
        personalShield = 0,
        groupShield    = 0,
        mitigatedTotal = 0,
        firstHealMs    = 0,
        firstShieldMs  = 0,
        lastActivityMs = 0,
    }
end

M.session = NewSession()
-- [cleanName] = { value = current shield, watchUntil = ms, activeUntil = ms }
M.shieldTargets = {}

local healWindow, shieldWindow
local displayDirty = true
local lastRenderSec = -1

local function MarkDirty() displayDirty = true end

local function HasSessionData(s)
    return s.healTotal > 0 or s.shieldTotal > 0 or s.mitigatedTotal > 0
end

local function ElapsedSeconds(startMs, nowMs)
    if startMs == 0 then return 0 end
    return max(0, (nowMs - startMs) / 1000)
end

function M:GetHPS()
    return healWindow and healWindow:GetRate() or 0
end

function M:GetShieldSPS()
    return shieldWindow and shieldWindow:GetRate() or 0
end

function M:GetOverallHPS()
    local s = self.session
    return s.healTotal / max(1, ElapsedSeconds(s.firstHealMs, GetGameTimeMilliseconds()))
end

function M:GetOverallSPS()
    local s = self.session
    return s.shieldTotal / max(1, ElapsedSeconds(s.firstShieldMs, GetGameTimeMilliseconds()))
end

-- Share of absorbed damage relative to absorbed + shielding applied.
function M:GetMitigatedPercent()
    local s = self.session
    local total = s.mitigatedTotal + s.shieldTotal
    if total <= 0 then return 0 end
    return s.mitigatedTotal / total * 100
end

-- ----------------------------------------------------------------------------
-- Battleground / best-stat history
-- ----------------------------------------------------------------------------
function M:SaveSessionToHistory()
    local saved, s = self.saved, self.session
    if not saved or not HasSessionData(s) then return end

    local mitigation = self:GetMitigatedPercent()
    saved.topHealing    = max(saved.topHealing or 0, s.healTotal)
    saved.topShielding  = max(saved.topShielding or 0, s.shieldTotal)
    saved.topMitigation = max(saved.topMitigation or 0, mitigation)

    saved.bgHistory = saved.bgHistory or {}
    table.insert(saved.bgHistory, {
        healing    = s.healTotal,
        shielding  = s.shieldTotal,
        mitigation = mitigation,
        timestamp  = GetDateStringFromTimestamp(GetTimeStamp()) or "",
    })
    while #saved.bgHistory > MAX_BG_HISTORY do
        table.remove(saved.bgHistory, 1)
    end
end

function M:GetSavedBGMaxStats()
    local saved = self.saved
    if not saved then return 0, 0, 0 end

    local heal  = saved.topHealing or 0
    local shield = saved.topShielding or 0
    local mitigation = saved.topMitigation or 0
    for _, entry in ipairs(saved.bgHistory or {}) do
        heal       = max(heal, tonumber(entry.healing) or 0)
        shield     = max(shield, tonumber(entry.shielding) or 0)
        mitigation = max(mitigation, tonumber(entry.mitigation) or 0)
    end
    return heal, shield, mitigation
end

function M:PrintSavedBGStats()
    if not self.saved then return end
    local heal, shield, mitigation = self:GetSavedBGMaxStats()
    Print(format("Best Stats | Healing: %s | Shielding: %s | Mitigation: %.1f%% | Entries: %d",
        FormatShortNumber(heal), FormatShortNumber(shield), mitigation, #(self.saved.bgHistory or {})))
end

function M:ResetSavedBGStats()
    if not self.saved then return end
    self.saved.topHealing = 0
    self.saved.topShielding = 0
    self.saved.topMitigation = 0
    self.saved.bgHistory = {}
    Print("Saved BG history cleared.")
end

-- Ends the current session: stores it in history (if anything happened) and
-- clears all live counters.
function M:Reset()
    self:SaveSessionToHistory()
    self.session = NewSession()
    self.shieldTargets = {}
    nameCache, nameCacheSize = {}, 0
    if healWindow then healWindow:Clear() end
    if shieldWindow then shieldWindow:Clear() end
    MarkDirty()
    self:UpdateDisplay()
end

-- ----------------------------------------------------------------------------
-- Healing
-- ----------------------------------------------------------------------------
local HEAL_RESULTS = {
    ACTION_RESULT_HEAL,
    ACTION_RESULT_CRITICAL_HEAL,
    ACTION_RESULT_HOT_TICK,
    ACTION_RESULT_HOT_TICK_CRITICAL,
}

local function OnHeal(_, _, isError, _, _, _, _, _, _, targetType, hitValue)
    if isError or not hitValue or hitValue <= 0 then return end

    local s = M.session
    local now = GetGameTimeMilliseconds()
    healWindow:Add(floor(now / 1000), hitValue)

    s.healTotal = s.healTotal + hitValue
    if targetType == COMBAT_UNIT_TYPE_PLAYER then
        s.personalHeal = s.personalHeal + hitValue
    else
        s.groupHeal = s.groupHeal + hitValue
    end
    if s.firstHealMs == 0 then s.firstHealMs = now end
    s.lastActivityMs = now
    MarkDirty()
end

-- ----------------------------------------------------------------------------
-- Shielding
--   1. A buff applied by the player marks the target as "watched".
--   2. Attribute-visual events report that unit's shield value; increases on a
--      watched unit count as shielding done by the player.
--   3. Damage absorbed by a watched, shielded unit counts as mitigation.
-- ----------------------------------------------------------------------------
local function OnEffectApplied(_, _, isError, _, _, _, _, _, targetName)
    if isError then return end
    local name = CleanName(targetName)
    if not name then return end

    local entry = M.shieldTargets[name]
    if not entry then
        entry = { value = 0, watchUntil = 0, activeUntil = 0 }
        M.shieldTargets[name] = entry
    end
    entry.watchUntil = GetGameTimeMilliseconds() + SHIELD_APPLY_WAIT_MS
end

local function FindShieldTarget(unitTag)
    local targets = M.shieldTargets
    if next(targets) == nil then return nil end

    local name = CleanName(GetUnitName(unitTag))
    if name and targets[name] then return targets[name] end
    name = CleanName(GetUnitDisplayName(unitTag))
    if name and targets[name] then return targets[name] end
    return nil
end

function M:OnShieldValueChanged(unitTag, newValue)
    local entry = FindShieldTarget(unitTag)
    if not entry then return end

    local now = GetGameTimeMilliseconds()
    newValue = tonumber(newValue) or 0
    local delta = newValue - entry.value
    entry.value = newValue

    if newValue > 0 then
        entry.activeUntil = now + SHIELD_STALE_MS
        entry.watchUntil = max(entry.watchUntil, entry.activeUntil)
    else
        entry.activeUntil = now + SHIELD_DROP_GRACE_MS
    end

    if delta <= 0 then return end

    local s = self.session
    shieldWindow:Add(floor(now / 1000), delta)
    s.shieldTotal = s.shieldTotal + delta
    if AreUnitsEqual(unitTag, "player") then
        s.personalShield = s.personalShield + delta
    else
        s.groupShield = s.groupShield + delta
    end
    if s.firstShieldMs == 0 then s.firstShieldMs = now end
    s.lastActivityMs = now
    MarkDirty()
end

local function OnShieldVisualAdded(_, unitTag, visual, _, _, _, value)
    if visual ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
    M:OnShieldValueChanged(unitTag, value)
end

local function OnShieldVisualUpdated(_, unitTag, visual, _, _, _, _, newValue)
    if visual ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
    M:OnShieldValueChanged(unitTag, newValue)
end

local function OnShieldVisualRemoved(_, unitTag, visual)
    if visual ~= ATTRIBUTE_VISUAL_POWER_SHIELDING then return end
    M:OnShieldValueChanged(unitTag, 0)
end

local function OnDamageShielded(_, _, isError, _, _, _, _, _, targetName, _, hitValue)
    if isError or not hitValue or hitValue <= 0 then return end
    if next(M.shieldTargets) == nil then return end

    local name = CleanName(targetName)
    local entry = name and M.shieldTargets[name]
    if not entry or entry.activeUntil <= GetGameTimeMilliseconds() then return end

    M.session.mitigatedTotal = M.session.mitigatedTotal + hitValue
    MarkDirty()
end

local function PruneShieldTargets(now)
    for name, entry in pairs(M.shieldTargets) do
        if now > entry.watchUntil and now > entry.activeUntil then
            M.shieldTargets[name] = nil
        end
    end
end

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------
local BACKDROP_PAD_X, BACKDROP_PAD_Y = 14, 10

function M:CreateUI()
    local wm = WINDOW_MANAGER
    local root = wm:CreateTopLevelWindow("HPSMeterControl")
    root:SetMouseEnabled(false)
    root:SetAnchorFill(GuiRoot)

    local backdrop = wm:CreateControl("HPSMeterBackdrop", root, CT_BACKDROP)
    backdrop:SetCenterTexture("EsoUI/Art/Miscellaneous/white.dds")
    backdrop:SetEdgeTexture("EsoUI/Art/Miscellaneous/white.dds", 1, 1, 2)
    backdrop:SetInsets(0, 0, -1, -1)
    backdrop:SetCenterColor(HexToRGBA("132c1f", 0.72))
    backdrop:SetEdgeColor(HexToRGBA("8ecf9a", 0.95))
    backdrop:SetDrawLevel(0)

    local shadow = wm:CreateControl("HPSMeterLabelShadow", root, CT_LABEL)
    shadow:SetColor(0.05, 0.14, 0.08, 0.95)
    shadow:SetDrawLevel(1)

    local label = wm:CreateControl("HPSMeterLabel", root, CT_LABEL)
    label:SetDrawLevel(2)

    shadow:SetAnchor(TOPLEFT, label, TOPLEFT, 1, 1)
    backdrop:SetAnchor(TOPLEFT, label, TOPLEFT, -BACKDROP_PAD_X, -BACKDROP_PAD_Y)
    backdrop:SetAnchor(BOTTOMRIGHT, label, BOTTOMRIGHT, BACKDROP_PAD_X, BACKDROP_PAD_Y)

    self.control, self.backdropControl = root, backdrop
    self.labelControl, self.labelShadowControl = label, shadow

    self:ApplyLayout()
end

function M:ApplyLayout()
    local saved, label = self.saved, self.labelControl
    if not label then return end

    local scale = saved.scale
    local font = format("$(MEDIUM_FONT)|%d|outline", max(14, floor(22 * scale)))
    for _, ctrl in ipairs({ label, self.labelShadowControl }) do
        ctrl:SetFont(font)
        ctrl:SetScale(scale)
    end

    label:ClearAnchors()
    label:SetAnchor(TOPLEFT, self.control, TOPLEFT, saved.labelX, saved.labelY)

    local hidden = not saved.showLabel
    label:SetHidden(hidden)
    self.labelShadowControl:SetHidden(hidden)
    self.backdropControl:SetHidden(hidden)

    MarkDirty()
    self:UpdateDisplay()
end

function M:BuildDisplayText()
    local saved, s = self.saved, self.session
    local hColor, sColor, oColor = saved.labelColor, saved.shieldColor, saved.overallColor
    local showShields = saved.showShields
    local lines = {}

    local function AddLine(parts)
        if #parts > 0 then lines[#lines + 1] = table.concat(parts, "  ") end
    end

    -- Rolling rates
    local rates = { Colorize(hColor, "HPS: " .. FormatShortNumber(self:GetHPS())) }
    if showShields then
        rates[2] = Colorize(sColor, "SPS: " .. FormatShortNumber(self:GetShieldSPS()))
    end
    AddLine(rates)

    -- Group / personal totals (only once non-zero)
    local group, personal = {}, {}
    if s.groupHeal > 0 then
        group[#group + 1] = Colorize(hColor, "Heal Group: " .. FormatShortNumber(s.groupHeal))
    end
    if s.personalHeal > 0 then
        personal[#personal + 1] = Colorize(hColor, "Heal Personal: " .. FormatShortNumber(s.personalHeal))
    end
    if showShields then
        if s.groupShield > 0 then
            group[#group + 1] = Colorize(sColor, "Shield Group: " .. FormatShortNumber(s.groupShield))
        end
        if s.personalShield > 0 then
            personal[#personal + 1] = Colorize(sColor, "Shield Personal: " .. FormatShortNumber(s.personalShield))
        end
    end
    AddLine(group)
    AddLine(personal)

    if showShields then
        AddLine({ Colorize(oColor, format("Mitigated: %.1f%%", self:GetMitigatedPercent())) })
    end

    if saved.showOverall then
        local overall = { Colorize(oColor, "Overall HPS: " .. FormatShortNumber(self:GetOverallHPS())) }
        if showShields then
            overall[2] = Colorize(oColor, "Overall SPS: " .. FormatShortNumber(self:GetOverallSPS()))
        end
        AddLine(overall)
    end

    return table.concat(lines, "\n")
end

function M:UpdateDisplay()
    if not self.labelControl or not self.saved.showLabel then return end
    local text = self:BuildDisplayText()
    self.labelControl:SetText(text)
    self.labelShadowControl:SetText(StripColorCodes(text))
    displayDirty = false
    lastRenderSec = floor(GetGameTimeMilliseconds() / 1000)
end

-- ----------------------------------------------------------------------------
-- Chat output
-- ----------------------------------------------------------------------------
function M:LinkHealingData()
    local s = self.session
    local msg = format(
        "%s | Heal %s (Self %s / Group %s) | HPS %s | Shield %s (Self %s / Group %s) | Avg SPS %s | Absorbed %s (%.1f%%)",
        ADDON_TITLE,
        FormatShortNumber(s.healTotal), FormatShortNumber(s.personalHeal), FormatShortNumber(s.groupHeal),
        FormatShortNumber(self:GetHPS()),
        FormatShortNumber(s.shieldTotal), FormatShortNumber(s.personalShield), FormatShortNumber(s.groupShield),
        FormatShortNumber(self:GetOverallSPS()),
        FormatShortNumber(s.mitigatedTotal), self:GetMitigatedPercent())

    if IsConsoleUI() then
        Print(msg) -- StartChatInput is not available on console
    else
        StartChatInput(msg)
    end
end

local SLASH_HELP = {
    { "/bloomhps",           "Show this help" },
    { "/bloomhpslink",       "Link current healing data to chat (PC only)" },
    { "/bloomhpsstats",      "Show saved battleground stats (aliases: /bloomhpsbg, /bloomhpsmax, /bloomhpsbest)" },
    { "/bloomhpsreset",      "Reset current meter data" },
    { "/bloomhpsresetstats", "Reset saved battleground stats (alias: /bloomhpsclear)" },
}

function M:PrintHelp()
    for _, entry in ipairs(SLASH_HELP) do
        Print(entry[1] .. " - " .. entry[2])
    end
end

local function RegisterSlashCommands()
    local function PrintStats() M:PrintSavedBGStats() end
    local function ResetStats() M:ResetSavedBGStats() end

    SLASH_COMMANDS["/bloomhps"]           = function() M:PrintHelp() end
    SLASH_COMMANDS["/bloomhpslink"]       = function() M:LinkHealingData() end
    SLASH_COMMANDS["/bloomhpsreset"]      = function() M:Reset() end
    SLASH_COMMANDS["/bloomhpsstats"]      = PrintStats
    SLASH_COMMANDS["/bloomhpsbg"]         = PrintStats
    SLASH_COMMANDS["/bloomhpsmax"]        = PrintStats
    SLASH_COMMANDS["/bloomhpsbest"]       = PrintStats
    SLASH_COMMANDS["/bloomhpsresetstats"] = ResetStats
    SLASH_COMMANDS["/bloomhpsclear"]      = ResetStats
end

-- ----------------------------------------------------------------------------
-- Settings (LibAddonMenu-2.0)
-- ----------------------------------------------------------------------------
local function SavedOption(key, onChange)
    return function() return M.saved[key] end,
        function(value)
            M.saved[key] = value
            if onChange then onChange(value) end
        end
end

local function ColorOption(name, key, fallback)
    local getFunc = function() return M.saved[key] end
    local setFunc = function(value)
        M.saved[key] = SanitizeHex(value, fallback)
        MarkDirty()
        M:UpdateDisplay()
    end
    return {
        type = "editbox", name = name, tooltip = "6-digit hex color, e.g. " .. fallback,
        getFunc = getFunc, setFunc = setFunc, default = fallback,
    }
end

local function Slider(name, key, minValue, maxValue, step, onChange, tooltip)
    local getFunc, setFunc = SavedOption(key, onChange)
    return {
        type = "slider", name = name, tooltip = tooltip,
        min = minValue, max = maxValue, step = step, decimals = step < 1 and 2 or 0,
        getFunc = getFunc, setFunc = setFunc, default = M.defaults[key],
    }
end

local function Checkbox(name, key, onChange)
    local getFunc, setFunc = SavedOption(key, onChange)
    return { type = "checkbox", name = name, getFunc = getFunc, setFunc = setFunc, default = M.defaults[key] }
end

function M:CreateSettingsMenu()
    local LAM = LibAddonMenu2
    if not LAM or not LAM.RegisterAddonPanel then return end

    local panelName = ADDON_NAME .. "Panel"
    LAM:RegisterAddonPanel(panelName, {
        type = "panel",
        name = ADDON_TITLE,
        displayName = ADDON_TITLE,
        author = ADDON_AUTHOR,
        version = ADDON_VERSION,
        registerForRefresh = true,
        registerForDefaults = true,
    })

    local function Relayout() M:ApplyLayout() end
    local function Redraw() MarkDirty(); M:UpdateDisplay() end
    local function ResizeWindows(seconds)
        M.saved.shieldWindow = seconds
        healWindow:Resize(seconds)
        shieldWindow:Resize(seconds)
        Redraw()
    end

    LAM:RegisterOptionControls(panelName, {
        {
            type = "button", name = "Reset Bloom HPS Data", width = "full",
            tooltip = "Clears the current healing and shielding data",
            warning = "This will clear the current Bloom HPS data",
            func = function() M:Reset() end,
        },
        {
            type = "button", name = "Reset Bloom HPS BG Stats", width = "full",
            tooltip = "Clears saved BG stats (top healing, shielding, mitigation)",
            warning = "This will permanently clear the saved Bloom HPS BG stats",
            func = function() M:ResetSavedBGStats() end,
        },
        {
            type = "button", name = "Bloom HPS Help", width = "full",
            tooltip = "Prints the list of slash commands to chat",
            func = function() M:PrintHelp() end,
        },

        { type = "header", name = "Display" },
        Checkbox("Show Meter", "showLabel", Relayout),
        Slider("Position X", "labelX", 0, 2000, 1, Relayout),
        Slider("Position Y", "labelY", 0, 2000, 1, Relayout),
        Slider("Scale", "scale", 0.1, 10, 0.05, Relayout),
        Slider("Rolling Window (seconds)", "window", 1, 60, 1, ResizeWindows,
            "Number of seconds HPS and SPS are averaged over"),

        { type = "header", name = "Healing" },
        ColorOption("Healing Color", "labelColor", DEFAULT_HEAL_COLOR),

        { type = "header", name = "Shielding" },
        Checkbox("Show Shielding & Mitigation", "showShields", Redraw),
        ColorOption("Shielding Color", "shieldColor", DEFAULT_SHIELD_COLOR),

        { type = "header", name = "Overall" },
        Checkbox("Show Overall HPS / SPS", "showOverall", Redraw),
        ColorOption("Overall / Mitigated Color", "overallColor", DEFAULT_OVERALL_COLOR),

        { type = "header", name = "Reset Timer" },
        Slider("Idle Reset Timer (seconds)", "resetTimer", 1, 900, 1, nil,
            "Seconds without healing or shielding before the meter resets. Default: 300 (5 min)"),
    })
end

-- ----------------------------------------------------------------------------
-- Event registration
-- ----------------------------------------------------------------------------
local function RegisterCombatEvent(namespace, handler, result, sourceIsPlayer)
    EVENT_MANAGER:RegisterForEvent(namespace, EVENT_COMBAT_EVENT, handler)
    if sourceIsPlayer then
        EVENT_MANAGER:AddFilterForEvent(namespace, EVENT_COMBAT_EVENT,
            REGISTER_FILTER_COMBAT_RESULT, result,
            REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
    else
        EVENT_MANAGER:AddFilterForEvent(namespace, EVENT_COMBAT_EVENT,
            REGISTER_FILTER_COMBAT_RESULT, result)
    end
end

local function OnTick()
    local now = GetGameTimeMilliseconds()
    local nowSec = floor(now / 1000)
    local s = M.session

    if s.lastActivityMs > 0 and now - s.lastActivityMs > (M.saved.resetTimer or 300) * 1000 then
        M:Reset()
        return
    end

    healWindow:Advance(nowSec)
    shieldWindow:Advance(nowSec)
    PruneShieldTargets(now)

    if displayDirty or nowSec ~= lastRenderSec then
        M:UpdateDisplay()
    end
end

local function OnBattlegroundStateChanged(_, _, newState)
    if newState == BATTLEGROUND_STATE_FINISHED or newState == BATTLEGROUND_STATE_POSTGAME then
        M:Reset() -- saves to history once; the second state change finds no data
    end
end

local function RegisterEvents()
    -- Each registration gets one result filter so the game only calls us for
    -- events we actually care about.
    for _, result in ipairs(HEAL_RESULTS) do
        RegisterCombatEvent(ADDON_NAME .. "_Heal_" .. result, OnHeal, result, true)
    end
    RegisterCombatEvent(ADDON_NAME .. "_EffectGained", OnEffectApplied, ACTION_RESULT_EFFECT_GAINED, true)
    RegisterCombatEvent(ADDON_NAME .. "_EffectGainedDuration", OnEffectApplied, ACTION_RESULT_EFFECT_GAINED_DURATION, true)
    RegisterCombatEvent(ADDON_NAME .. "_Shielded", OnDamageShielded, ACTION_RESULT_DAMAGE_SHIELDED, false)

    EVENT_MANAGER:RegisterForEvent(ADDON_NAME .. "_VisualAdded", EVENT_UNIT_ATTRIBUTE_VISUAL_ADDED, OnShieldVisualAdded)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME .. "_VisualUpdated", EVENT_UNIT_ATTRIBUTE_VISUAL_UPDATED, OnShieldVisualUpdated)
    EVENT_MANAGER:RegisterForEvent(ADDON_NAME .. "_VisualRemoved", EVENT_UNIT_ATTRIBUTE_VISUAL_REMOVED, OnShieldVisualRemoved)

    EVENT_MANAGER:RegisterForEvent(ADDON_NAME .. "_Battleground", EVENT_BATTLEGROUND_STATE_CHANGED, OnBattlegroundStateChanged)
    EVENT_MANAGER:RegisterForUpdate(ADDON_NAME .. "_Tick", TICK_MS, OnTick)
end

-- ----------------------------------------------------------------------------
-- Initialisation
-- ----------------------------------------------------------------------------
local function MigrateSettings(saved)
    saved.labelColor   = SanitizeHex(saved.labelColor, DEFAULT_HEAL_COLOR)
    saved.shieldColor  = SanitizeHex(saved.shieldColor, DEFAULT_SHIELD_COLOR)
    saved.overallColor = SanitizeHex(saved.overallColor, DEFAULT_OVERALL_COLOR)
    if (saved.themeVersion or 0) < 1 then
        -- Old releases defaulted every color to yellow.
        if saved.labelColor == "ffff00" then saved.labelColor = DEFAULT_HEAL_COLOR end
        if saved.shieldColor == "ffff00" then saved.shieldColor = DEFAULT_SHIELD_COLOR end
        if saved.overallColor == "ffff00" then saved.overallColor = DEFAULT_OVERALL_COLOR end
        saved.themeVersion = 1
    end
end

local function OnAddOnLoaded(_, addonName)
    if addonName ~= ADDON_NAME then return end
    EVENT_MANAGER:UnregisterForEvent(ADDON_NAME, EVENT_ADD_ON_LOADED)

    M.saved = ZO_SavedVars:NewAccountWide("HPSMeterSavedVars", 2, nil, M.defaults)
    MigrateSettings(M.saved)

    healWindow = RollingWindow:New(M.saved.window)
    shieldWindow = RollingWindow:New(M.saved.window)

    local ok, err = pcall(M.CreateUI, M)
    if not ok then Print("CreateUI error: " .. tostring(err)) end

    ok, err = pcall(M.CreateSettingsMenu, M)
    if not ok then Print("Settings menu error: " .. tostring(err)) end

    RegisterSlashCommands()
    RegisterEvents()
end

EVENT_MANAGER:RegisterForEvent(ADDON_NAME, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
