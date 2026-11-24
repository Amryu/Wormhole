local _, ns = ...
local L = ns.L

local button

local function Place()
    local angle = math.rad(ns.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 6
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Drag()
    local x, y = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = Minimap:GetCenter()
    ns.db.minimapAngle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
    Place()
end

-- Marks the button while a request waits.
function ns.FlashMinimapButton(on)
    ns.attention = on ~= false
    if button then button.alert:SetShown(ns.attention) end
    ns.UpdateOrb()
end

-- Screen button --------------------------------------------------------------
-- A round button to park anywhere, grey while the own service is off. It counts what waits and pulses
-- until the list was looked at. Click: requests or jobs. Right-click: main window.

local orb

local function Waiting()
    local count = 0
    for _ in pairs(ns.char.kind == "C" and ns.calls or ns.incoming) do count = count + 1 end
    return count
end

local function BuildOrb()
    local f = CreateFrame("Button", "WormholeOrb", UIParent)
    f:SetSize(40, 40)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:RegisterForDrag("LeftButton")
    local pos = ns.db.orbPos
    if pos then f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos[1], pos[2]) else f:SetPoint("CENTER", UIParent, "CENTER", 220, -120) end
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        ns.db.orbPos = { x, y }
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    end)
    f.icon = f:CreateTexture(nil, "BACKGROUND")
    f.icon:SetSize(26, 26)
    f.icon:SetPoint("CENTER", 0, 1)
    f.icon:SetTexture(ns.LOGO)
    pcall(function()
        local mask = f:CreateMaskTexture()
        mask:SetAllPoints(f.icon)
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        f.icon:AddMaskTexture(mask)
    end)
    local border = f:CreateTexture(nil, "OVERLAY")
    border:SetSize(68, 68)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    f:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    f.glow = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.glow:SetSize(44, 44)
    f.glow:SetPoint("CENTER", 0, 1)
    f.glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.6, 0.1)
    f.glow:Hide()
    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.count:SetPoint("BOTTOMRIGHT", 2, -2)
    f.count:SetTextColor(1, 0.25, 0.25)
    local elapsed = 0
    f:SetScript("OnUpdate", function(self, delta)
        if not self.glow:IsShown() then return end
        elapsed = elapsed + delta
        self.glow:SetAlpha(0.35 + 0.65 * math.abs(math.sin(elapsed * 3)))
    end)
    f:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then ns.ToggleWindow() else ns.ToggleRequests() end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Wormhole", 1, 1, 1)
        GameTooltip:AddLine(ns.KindName(ns.char.kind), 1, 0.82, 0)
        GameTooltip:AddLine(("%s: %s"):format(L["Click"], ns.char.kind == "C" and L["Clicker Jobs"] or L["Requests"]), 0.5, 0.5, 0.5)
        GameTooltip:AddLine(L["Right-Click: Wormhole"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", GameTooltip_Hide)
    return f
end

function ns.UpdateOrb()
    if not ns.db then return end
    local count = Waiting()
    local show = ns.db.orbShow
    if not orb then
        if not show then return end
        local ok, result = pcall(BuildOrb)
        if not ok then return end
        orb = result
    end
    orb:SetShown(show)
    if not show then return end
    orb:SetScale(ns.db.orbScale or 1)
    orb.icon:SetDesaturated(not ns.IsLive())
    orb.count:SetText(count > 0 and count or "")
    orb.glow:SetShown(ns.attention == true and count > 0)
end

function ns.UpdateMinimapButton()
    if not button then
        if not ns.db.minimapShow then return end
        button = CreateFrame("Button", "WormholeMinimapButton", Minimap)
        button:SetSize(31, 31)
        button:SetFrameStrata("MEDIUM")
        button:SetFrameLevel(8)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:RegisterForDrag("LeftButton")
        button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local icon = button:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER", 0, 1)
        icon:SetTexture(ns.LOGO)
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        button.alert = button:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        button.alert:SetPoint("CENTER", 0, 1)
        button.alert:SetText("|cffff2020!|r")
        button.alert:Hide()
        button:SetScript("OnClick", function(self, mouse)
            if self.alert:IsShown() then return ns.ShowRequests() end
            ns.ToggleWindow()
        end)
        button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", Drag) end)
        button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Wormhole", 1, 1, 1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
    button:SetShown(ns.db.minimapShow)
    Place()
end
