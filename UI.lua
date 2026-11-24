local ADDON, ns = ...
local L = ns.L

-- The setup window: the own service and how requests are handled. Offers are browsed on the world map.
local WIDTH, HEIGHT = 700, 470
local TOP = -36
local GREEN, GREY, GOLD, RED, ORANGE = "|cff40ff40", "|cff808080", "|cffffd100", "|cffff4040", "|cffff9040"

local window

local function HasTemplate(name)
    return C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo(name) and name or nil
end

-- Text ---------------------------------------------------------------------

local function ClickerText(offer)
    if (offer.ready or 0) >= 2 then return GREEN .. L["Ready"] .. "|r" end
    return ("%s%d/2|r"):format(ORANGE, offer.ready or 0)
end

function ns.OfferTooltip(owner, offer)
    local tip = GameTooltip
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    tip:AddDoubleLine(offer.name, ns.Money(offer.fee), 1, 1, 1, 1, 1, 1)
    tip:AddLine(("%s (%d, %d)"):format(ns.MapName(offer.map), offer.x * 100, offer.y * 100), 1, 0.82, 0)
    if offer.kind == "S" then
        tip:AddDoubleLine(L["Clickers"], ClickerText(offer), 1, 0.82, 0, 1, 1, 1)
    elseif offer.kind == "P" then
        for _, id in ipairs(offer.dests) do
            tip:AddLine(("|T%s:16|t %s"):format(tostring(ns.SpellIcon(id)), ns.PortalName(id)), 1, 1, 1)
        end
    end
    if offer.note and offer.note ~= "" then tip:AddLine(offer.note, 0.8, 0.8, 0.8, true) end
    tip:Show()
end

function ns.Whisper(name)
    local tell = ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
    if tell then tell(name) end
end

local function Ignore(name)
    local add = C_FriendList and (C_FriendList.AddIgnore or C_FriendList.AddOrDelIgnore)
    if add then pcall(add, name) end
    ns.offers[name] = nil
    ns.Cancel(name)
    ns.Refresh()
end

-- Right-click on an offer.
function ns.OfferMenu(owner, offer)
    if not offer or offer.own then return end
    local name = offer.name
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return ns.Whisper(name) end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(name)
        root:CreateButton(WHISPER or "Whisper", function() ns.Whisper(name) end)
        root:CreateButton(IGNORE or "Ignore", function() Ignore(name) end)
        root:CreateButton(CANCEL or "Cancel", function() end)
    end)
end

function ns.Select(name)
    ns.selected = name
    ns.Refresh()
end

-- Widgets ------------------------------------------------------------------

local function Button(parent, width, text)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetText(text or "")
    return button
end

local function Label(parent, text, font)
    local label = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
    label:SetText(text or "")
    return label
end

local function Check(parent, label, get, set)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(26, 26)
    local text = check.Text or check.text or check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetFontObject("GameFontHighlight")
    text:SetText(label)
    check.label = text
    check.Refresh = function() check:SetChecked(get() and true or false) end
    check:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        ns.Tick()
        ns.UpdateWindow()
    end)
    return check
end

local function Edit(parent, width, numeric, letters)
    local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    edit:SetSize(width, 20)
    edit:SetAutoFocus(false)
    if numeric then edit:SetNumeric(true) end
    edit:SetMaxLetters(letters)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    return edit
end

local function MoneyInput(parent, get, set)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(150, 24)
    frame.gold = Edit(frame, 54, true, 4)
    frame.gold:SetPoint("LEFT", 6, 0)
    local goldIcon = Label(frame, "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t")
    goldIcon:SetPoint("LEFT", frame.gold, "RIGHT", 3, 0)
    frame.silver = Edit(frame, 30, true, 2)
    frame.silver:SetPoint("LEFT", goldIcon, "RIGHT", 10, 0)
    local silverIcon = Label(frame, "|TInterface\\MoneyFrame\\UI-SilverIcon:14:14|t")
    silverIcon:SetPoint("LEFT", frame.silver, "RIGHT", 3, 0)
    local function Changed(_, user)
        if not user then return end
        set((tonumber(frame.gold:GetText()) or 0) * 10000 + (tonumber(frame.silver:GetText()) or 0) * 100)
    end
    frame.gold:SetScript("OnTextChanged", Changed)
    frame.silver:SetScript("OnTextChanged", Changed)
    frame.Refresh = function()
        local value = get() or 0
        if not frame.gold:HasFocus() then frame.gold:SetText(math.floor(value / 10000)) end
        if not frame.silver:HasFocus() then frame.silver:SetText(math.floor(value % 10000 / 100)) end
    end
    return frame
end

-- My offer -----------------------------------------------------------------

local SUSPEND = { AFK = "AFK", INSTANCE = "In Instance", NOPOS = "No Position", NODEST = "No Destinations" }

local function OfferStatus()
    if not ns.char.active then return GREY .. L["Inactive"] .. "|r" end
    local reason = ns.Suspended()
    if reason then
        local label = reason == "AFK" and (AFK or "AFK") or L[SUSPEND[reason]]
        return ("%s%s: %s|r"):format(ORANGE, L["Paused"], label)
    end
    return GREEN .. L["Active"] .. "|r"
end

local RANGES = { 100, 200, 300, 500, 1000, 0 }

local function UpdateOffer()
    local panel = window.offer
    local char = ns.char
    local kind = char.kind
    panel.role:SetText(ns.KindName(kind))
    panel.role:SetEnabled(#ns.Roles() > 1)
    for _, widget in ipairs(panel.provider) do widget:SetShown(kind ~= "C") end
    panel.fee:Refresh()
    if not panel.note:HasFocus() then panel.note:SetText(char.note or "") end

    for _, widget in ipairs(panel.warlock) do widget:SetShown(kind == "S") end
    panel.pay:Refresh()
    panel.nearbyCount:SetText(("%s: %d/2"):format(L["Clickers Nearby"], ns.ClickersNearby()))

    for _, widget in ipairs(panel.clicker) do widget:SetShown(kind == "C") end
    panel.range:SetText(char.range == 0 and L["Same Zone"] or ("%d %s"):format(char.range, L["yd"]))

    panel.destLabel:SetShown(kind == "P")
    local known = kind == "P" and ns.KnownPortals() or {}
    for index, check in ipairs(panel.portals) do
        local id = known[index]
        check:SetShown(id ~= nil)
        if id then
            check.id = id
            check.label:SetText(ns.PortalName(id))
            check:SetChecked(not char.portalsOff[id])
        end
    end
    panel.autoAfk:Refresh()
    panel.autoInstance:Refresh()
    panel.toggle:SetText(char.active and L["Deactivate"] or L["Activate"])
    panel.status:SetText(OfferStatus())
    panel.requests:SetText(kind == "C" and L["Clicker Jobs"] or L["Requests"])
    panel.autoInvite:SetShown(kind ~= "C")
    panel.autoInvite:Refresh()
    panel.autoClickers:SetShown(kind == "S")
    panel.autoClickers:Refresh()
end

function ns.UpdateWindow()
    if not (window and window:IsShown()) then return end
    window.title:SetText(ns.testMode and ("Wormhole (%s)"):format(L["Test Mode"]) or "Wormhole")
    local status, r, g, b = ns.NetStatus()
    window.net:SetText(status)
    window.net:SetTextColor(r, g, b)
    UpdateOffer()
end

-- Window -------------------------------------------------------------------

local function BuildOffer(frame)
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", 20, TOP)
    panel:SetPoint("BOTTOMRIGHT", -20, 36)
    frame.offer = panel
    local char = ns.char
    local CONTROL = 150

    local function Row(text, y)
        local label = Label(panel, text)
        label:SetPoint("TOPLEFT", 0, y - 5)
        return label
    end

    Row(L["Service"], 0)
    panel.role = Button(panel, 170)
    panel.role:SetPoint("TOPLEFT", CONTROL, 0)
    panel.role:SetScript("OnClick", function()
        local roles = ns.Roles()
        local current = 1
        for index, kind in ipairs(roles) do
            if kind == char.kind then current = index end
        end
        local kind = roles[current % #roles + 1]
        -- What waited was meant for the old service.
        if kind ~= char.kind then
            ns.EndCall()
            ns.DeclineAll()
        end
        char.kind = kind
        ns.Tick()
        ns.UpdateWindow()
    end)

    -- Warlock and mage.
    local feeLabel = Row(L["Fee"], -34)
    panel.fee = MoneyInput(panel, function() return char.fee[char.kind] end, function(value) char.fee[char.kind] = value end)
    panel.fee:SetPoint("TOPLEFT", CONTROL, -34)
    local noteLabel = Row(L["Note"], -68)
    panel.note = Edit(panel, 280, false, ns.NOTE_MAX)
    panel.note:SetPoint("TOPLEFT", CONTROL + 6, -70)
    panel.note:SetScript("OnTextChanged", function(self, user)
        if user then char.note = self:GetText() end
    end)
    panel.provider = { feeLabel, panel.fee, noteLabel, panel.note }

    -- Warlock: what a hired clicker gets, paid out of the fee.
    local payLabel = Row(L["Clicker Pay"], -102)
    panel.pay = MoneyInput(panel, function() return char.clickerPay end, function(value) char.clickerPay = value end)
    panel.pay:SetPoint("TOPLEFT", CONTROL, -102)
    local payHint = Label(panel, L["Included in your fee."], "GameFontDisable")
    payHint:SetPoint("LEFT", panel.pay, "RIGHT", 8, 0)
    panel.nearbyCount = Label(panel, "", "GameFontHighlight")
    panel.nearbyCount:SetPoint("TOPLEFT", CONTROL + 4, -141)
    panel.warlock = { payLabel, panel.pay, payHint, panel.nearbyCount }

    -- Clicker: how far away a warlock may be.
    local rangeLabel = Row(L["Range"], -34)
    panel.range = Button(panel, 170)
    panel.range:SetPoint("TOPLEFT", CONTROL, -34)
    panel.range:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    panel.range:SetScript("OnClick", function(_, mouse)
        local current = 1
        for index, value in ipairs(RANGES) do
            if value == char.range then current = index end
        end
        char.range = RANGES[(current - 1 + (mouse == "RightButton" and -1 or 1)) % #RANGES + 1]
        ns.UpdateWindow()
    end)
    local rangeHint = Label(panel, L["Alerts you when a warlock in range needs clickers."], "GameFontHighlight")
    rangeHint:SetPoint("TOPLEFT", CONTROL + 4, -73)
    rangeHint:SetWidth(420)
    rangeHint:SetJustifyH("LEFT")
    panel.clicker = { rangeLabel, panel.range, rangeHint }

    panel.destLabel = Row(L["Destinations"], -102)
    panel.portals = {}
    for index = 1, 10 do
        local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        check:SetSize(26, 26)
        check:SetPoint("TOPLEFT", CONTROL + ((index - 1) % 2) * 150, -100 - math.floor((index - 1) / 2) * 26)
        local text = check.Text or check.text or check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetFontObject("GameFontHighlight")
        check.label = text
        check:SetScript("OnClick", function(self)
            char.portalsOff[self.id] = not self:GetChecked() and true or nil
            ns.Tick()
            ns.UpdateWindow()
        end)
        panel.portals[index] = check
    end

    Row(L["Pause"], -246)
    panel.autoAfk = Check(panel, L["While AFK"], function() return ns.db.autoAfk end, function(value) ns.db.autoAfk = value end)
    panel.autoAfk:SetPoint("TOPLEFT", CONTROL, -240)
    panel.autoInstance = Check(panel, L["In Instances"], function() return ns.db.autoInstance end, function(value) ns.db.autoInstance = value end)
    panel.autoInstance:SetPoint("TOPLEFT", CONTROL, -266)

    panel.toggle = Button(panel, 170)
    panel.toggle:SetHeight(28)
    panel.toggle:SetPoint("TOPLEFT", CONTROL, -312)
    panel.toggle:SetScript("OnClick", function()
        ns.SetActive(not char.active)
        ns.UpdateWindow()
    end)
    panel.status = Label(panel, "", "GameFontHighlight")
    panel.status:SetPoint("LEFT", panel.toggle, "RIGHT", 12, 0)

    -- Requests.
    local X = 470
    panel.requests = Button(panel, 170)
    panel.requests:SetPoint("TOPLEFT", X, 0)
    panel.requests:SetScript("OnClick", function() ns.ShowRequests() end)
    panel.autoInvite = Check(panel, L["Auto Invite"], function() return char.autoInvite end, function(value) char.autoInvite = value end)
    panel.autoInvite:SetPoint("TOPLEFT", X, -34)
    panel.autoClickers = Check(panel, L["Auto Invite Clickers"], function() return char.autoClickers end, function(value) char.autoClickers = value end)
    panel.autoClickers:SetPoint("TOPLEFT", X, -60)
end

local function Build()
    local template = HasTemplate("BasicFrameTemplateWithInset")
    local frame = CreateFrame("Frame", "WormholeFrame", UIParent, template or "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if not template then
        frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    end
    local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if not frame.TitleText then title:SetPoint("TOP", 0, -6) end
    title:SetText("Wormhole")
    frame.title = title
    local close = frame.CloseButton or CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    if not frame.CloseButton then close:SetPoint("TOPRIGHT", 2, 2) end
    close:SetScript("OnClick", function() frame:Hide() end)
    tinsert(UISpecialFrames, "WormholeFrame")

    BuildOffer(frame)

    local options = Button(frame, 100, GAMEMENU_OPTIONS or "Options")
    options:SetHeight(22)
    options:SetPoint("BOTTOMRIGHT", -12, 7)
    options:SetScript("OnClick", function() if ns.OpenOptions then ns.OpenOptions() end end)
    -- Offers live on the world map.
    local find = Button(frame, 150, L["Find Offers"])
    find:SetHeight(22)
    find:SetPoint("RIGHT", options, "LEFT", -4, 0)
    find:SetScript("OnClick", function() if ns.OpenWorldMap then ns.OpenWorldMap() end end)
    frame.net = Label(frame, "", "GameFontHighlight")
    frame.net:SetPoint("BOTTOMLEFT", 180, 13)

    frame:SetScript("OnShow", function()
        ns.Tick()
        ns.UpdateWindow()
    end)
    frame:Hide()
    return frame
end

function ns.WindowShown()
    return window ~= nil and window:IsShown()
end

function ns.ToggleWindow(show)
    if not window then
        local ok, result = pcall(Build)
        if not ok then return ns.Print(tostring(result)) end
        window = result
    end
    if show then window:Show() else window:SetShown(not window:IsShown()) end
    ns.UpdateWindow()
end
