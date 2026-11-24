local ADDON, ns = ...
local L = ns.L

local WIDTH, HEIGHT = 960, 600
local MAP_W, MAP_H = 480, 320
local TOP = -62
local RIGHT_X = 506
local ROW_H = 22
local COLS = {
    { key = "name", x = 4, w = 110, justify = "LEFT" },
    { key = "zone", x = 118, w = 112, justify = "LEFT" },
    { key = "status", x = 234, w = 72, justify = "LEFT" },
    { key = "fee", x = 308, w = 62, justify = "RIGHT" },
    { key = "dist", x = 374, w = 42, justify = "RIGHT" },
}
local GREEN, GREY, GOLD, RED, ORANGE = "|cff40ff40", "|cff808080", "|cffffd100", "|cffff4040", "|cffff9040"

local window
local rows = {}
local offerMode = false
local filterText = ""
local selDest

local function HasTemplate(name)
    return C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo(name) and name or nil
end

-- Text ---------------------------------------------------------------------

local function DistText(dist)
    if not dist then return GREY .. "-|r" end
    if dist >= 1000 then return ("%.1fk"):format(dist / 1000) end
    return ("%d"):format(dist)
end

local function ClickerText(offer)
    if (offer.ready or 0) >= 2 then return GREEN .. L["Ready"] .. "|r" end
    return ("%s%d/2|r"):format(ORANGE, offer.ready or 0)
end

local function StatusText(offer)
    if offer.kind == "S" then return ClickerText(offer) end
    if offer.kind == "P" then
        local icons = {}
        for index, id in ipairs(offer.dests) do
            if index <= 4 then icons[index] = ("|T%s:16|t"):format(tostring(ns.SpellIcon(id))) end
        end
        return table.concat(icons, " ")
    end
    return ""
end

local function StateText(name)
    local request = ns.outgoing[name]
    if not request then return "" end
    if request.state == "ACCEPTED" then return GREEN .. L["Accepted"] .. "|r" end
    if request.state == "DECLINED" then return RED .. L["Declined"] .. "|r" end
    return GOLD .. L["Requested"] .. "|r"
end

local function Pending(name)
    local request = ns.outgoing[name]
    return request and request.state == "SENT"
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

function ns.Select(name)
    if ns.selected ~= name then selDest = nil end
    ns.selected = name
    ns.UpdateWindow()
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
    frame.gold = Edit(frame, 54, true, 5)
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

-- Browse -------------------------------------------------------------------

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(420, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.picked = row:CreateTexture(nil, "BACKGROUND")
    row.picked:SetAllPoints()
    row.picked:SetColorTexture(1, 0.82, 0, 0.18)
    row.requested = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.requested:SetAllPoints()
    row.requested:SetColorTexture(0.3, 0.8, 1, 0.22)
    row.text = {}
    for column, col in ipairs(COLS) do
        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", col.x, 0)
        text:SetWidth(col.w)
        text:SetJustifyH(col.justify)
        text:SetWordWrap(false)
        row.text[column] = text
    end
    row:SetScript("OnEnter", function(self) ns.OfferTooltip(self, self.offer) end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function(self) ns.Select(self.offer.name) end)
    return row
end

-- Destinations any listed mage offers, for the filter button.
local function Destinations()
    local seen, list = {}, { 0 }
    for _, offer in pairs(ns.offers) do
        for _, id in ipairs(offer.kind == "P" and offer.dests or {}) do
            if not seen[id] then
                seen[id] = true
                list[#list + 1] = id
            end
        end
    end
    table.sort(list)
    return list
end

local function UpdateDetail()
    local detail = window.detail
    local offer = ns.selected and ns.offers[ns.selected]
    if offer and offer.kind ~= ns.db.view then offer = nil end
    detail.empty:SetShown(not offer)
    detail.body:SetShown(offer ~= nil)
    if not offer then return end
    detail.name:SetText(offer.name)
    local where = ("%s (%d, %d)"):format(ns.MapName(offer.map), offer.x * 100, offer.y * 100)
    if offer.dist then where = ("%s   %s %s"):format(where, DistText(offer.dist), L["yd"]) end
    detail.where:SetText(where)
    local info = ("%s: %s"):format(L["Fee"], ns.Money(offer.fee))
    if offer.kind == "S" then
        info = ("%s    %s: %s"):format(info, L["Clickers"], ClickerText(offer))
    end
    detail.info:SetText(info)
    detail.note:SetText(offer.note or "")

    local dests = offer.kind == "P" and offer.dests or {}
    if offer.kind == "P" then
        local valid = false
        for _, id in ipairs(dests) do valid = valid or id == selDest end
        if not valid then
            selDest = dests[1]
            for _, id in ipairs(dests) do
                if id == ns.db.dest then selDest = id end
            end
        end
    end
    for index, button in ipairs(detail.dests) do
        local id = dests[index]
        button:SetShown(id ~= nil)
        if id then
            button.id = id
            button.icon:SetTexture(ns.SpellIcon(id))
            if id == selDest then button.edge:SetColorTexture(1, 0.82, 0, 1) else button.edge:SetColorTexture(0.2, 0.2, 0.2, 1) end
        end
    end
    detail.destName:SetText(offer.kind == "P" and selDest and ns.PortalName(selDest) or "")
    local pending = Pending(offer.name)
    detail.request:SetText(pending and L["Cancel Request"] or offer.kind == "S" and L["Request Summon"] or L["Request Portal"])
    detail.request:SetEnabled(not offer.own and (pending or ns.OpenRequests() < ns.REQUEST_MAX))
    detail.whisper:SetEnabled(not offer.own and not offer.fake)
    detail.state:SetText(StateText(offer.name))
end

local function UpdateBrowse()
    local db = ns.db
    local kind = db.view
    local view = window.map
    local map = view.mapID
    local all = ns.List(kind, nil, { text = filterText, readyOnly = db.readyOnly, maxFee = db.maxFee, dest = db.dest }, db.sort[kind], db.sortDown[kind])
    local listed = all
    if map ~= ns.RootMap() then
        listed = {}
        for _, offer in ipairs(all) do
            if ns.InMap(offer.map, map) then listed[#listed + 1] = offer end
        end
    end
    local shown, here = ns.Map.Update(view, all, ns.selected, db.pinCap)
    local continent = ns.Continent(map) or ns.RootMap()
    for _, button in ipairs(window.continents) do button:SetEnabled(button.map ~= map) end
    window.zone:SetText(map ~= continent and ns.MapName(map) or "")
    window.pinText:SetText(here > shown and ("%d / %d"):format(shown, here) or "")
    window.back:SetEnabled(ns.Map.ParentOf(map) ~= nil)

    window.readyOnly:SetShown(kind == "S")
    window.readyOnly:Refresh()
    window.dest:SetShown(kind == "P")
    window.dest:SetText(db.dest == 0 and L["Any Destination"] or ns.PortalName(db.dest))
    if not window.maxFee:HasFocus() then window.maxFee:SetText(db.maxFee > 0 and math.floor(db.maxFee / 10000) or "") end
    for column, header in ipairs(window.headers) do
        local key = COLS[column].key
        local label = key == "name" and (NAME or "Name") or key == "zone" and (ZONE or "Zone") or key == "fee" and L["Fee"] or key == "dist" and L["Dist"]
            or kind == "S" and L["Clickers"] or L["Portals"]
        header:SetText(db.sort[kind] == key and (GOLD .. label .. "|r") or label)
    end

    for index, offer in ipairs(listed) do
        local row = rows[index] or CreateRow(window.content, index)
        rows[index] = row
        row.offer = offer
        row.text[1]:SetText(offer.own and (GREEN .. offer.name .. "|r") or offer.name)
        row.text[2]:SetText(offer.zone)
        row.text[3]:SetText(StatusText(offer))
        row.text[4]:SetText(ns.Money(offer.fee))
        row.text[5]:SetText(DistText(offer.dist))
        row.picked:SetShown(offer.name == ns.selected)
        local request = ns.outgoing[offer.name]
        row.requested:SetShown(request ~= nil and request.state ~= "DECLINED")
        row:Show()
    end
    for index = #listed + 1, #rows do rows[index]:Hide() end
    window.content:SetHeight(math.max(#listed * ROW_H, 1))
    window.none:SetShown(#listed == 0)
    window.count:SetText(("%s: %d"):format(L["Offers"], #listed))
    UpdateDetail()
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
    panel.test:Refresh()
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
    local db = ns.db
    window.tabs[1]:SetEnabled(offerMode or db.view ~= "S")
    window.tabs[2]:SetEnabled(offerMode or db.view ~= "P")
    window.mine:SetEnabled(not offerMode)
    window.browse:SetShown(not offerMode)
    window.offer:SetShown(offerMode)
    window.own:SetText(OfferStatus())
    window.title:SetText(ns.testMode and ("Wormhole (%s)"):format(L["Test Mode"]) or "Wormhole")
    local status, r, g, b = ns.NetStatus()
    window.net:SetText(status)
    window.net:SetTextColor(r, g, b)
    if offerMode then UpdateOffer() else UpdateBrowse() end
end

-- Window -------------------------------------------------------------------

local function BuildBrowse(frame)
    local browse = CreateFrame("Frame", nil, frame)
    browse:SetAllPoints()
    frame.browse = browse

    frame.map = ns.Map.Create(browse, MAP_W, MAP_H)
    frame.map:SetPoint("TOPLEFT", 14, TOP)
    frame.map.onChange = ns.UpdateWindow

    frame.back = Button(browse, 70, BACK or "Back")
    frame.back:SetPoint("TOPLEFT", frame.map, "BOTTOMLEFT", 0, -6)
    frame.back:SetScript("OnClick", function()
        local parent = ns.Map.ParentOf(frame.map.mapID)
        if parent then ns.Map.Go(frame.map, parent) end
    end)
    -- Kalimdor and Eastern Kingdoms.
    frame.continents = {}
    local anchor = frame.back
    for index, id in ipairs({ 1414, 1415 }) do
        local button = Button(browse, index == 1 and 100 or 160, ns.MapName(id))
        button:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        button.map = id
        button:SetScript("OnClick", function() ns.Map.Go(frame.map, id) end)
        frame.continents[index] = button
        anchor = button
    end
    frame.zone = Label(browse, "", "GameFontNormalLarge")
    frame.zone:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    frame.zone:SetWidth(118)
    frame.zone:SetJustifyH("LEFT")
    frame.zone:SetWordWrap(false)
    frame.pinText = Label(frame.map.overlay, "", "GameFontHighlight")
    frame.pinText:SetPoint("BOTTOMRIGHT", -6, 6)

    -- Selected offer.
    local detail = CreateFrame("Frame", nil, browse)
    detail:SetPoint("TOPLEFT", frame.map, "BOTTOMLEFT", 0, -38)
    detail:SetPoint("BOTTOMRIGHT", browse, "BOTTOMLEFT", 14 + MAP_W, 36)
    frame.detail = detail
    detail.empty = Label(detail, L["Select an Offer"], "GameFontDisable")
    detail.empty:SetPoint("CENTER")
    local body = CreateFrame("Frame", nil, detail)
    body:SetAllPoints()
    detail.body = body
    detail.name = Label(body, "", "GameFontNormalLarge")
    detail.name:SetPoint("TOPLEFT", 2, -2)
    detail.state = Label(body, "", "GameFontHighlight")
    detail.state:SetPoint("LEFT", detail.name, "RIGHT", 12, 0)
    detail.where = Label(body, "", "GameFontHighlight")
    detail.where:SetPoint("TOPLEFT", 2, -24)
    detail.info = Label(body, "", "GameFontHighlight")
    detail.info:SetPoint("TOPLEFT", 2, -44)
    detail.note = Label(body, "", "GameFontHighlight")
    detail.note:SetPoint("TOPLEFT", 2, -64)
    detail.note:SetWidth(MAP_W - 4)
    detail.note:SetJustifyH("LEFT")
    detail.note:SetWordWrap(false)
    detail.note:SetTextColor(0.8, 0.8, 0.8)
    detail.dests = {}
    for index = 1, 10 do
        local button = CreateFrame("Button", nil, body)
        button:SetSize(26, 26)
        button:SetPoint("TOPLEFT", 2 + (index - 1) * 30, -86)
        button.edge = button:CreateTexture(nil, "BACKGROUND")
        button.edge:SetAllPoints()
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetPoint("TOPLEFT", 2, -2)
        button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        button:SetScript("OnClick", function(self)
            selDest = self.id
            ns.UpdateWindow()
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(ns.PortalName(self.id), 1, 1, 1)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
        detail.dests[index] = button
    end
    detail.request = Button(body, 170)
    detail.request:SetPoint("BOTTOMLEFT", 0, 0)
    detail.request:SetScript("OnClick", function()
        local offer = ns.selected and ns.offers[ns.selected]
        if not offer then return end
        if Pending(offer.name) then return ns.Cancel(offer.name) end
        if offer.kind == "S" then ns.Request(offer.name, "S") elseif selDest then ns.Request(offer.name, "P", selDest) end
    end)
    detail.destName = Label(body, "", "GameFontHighlight")
    detail.destName:SetPoint("LEFT", detail.request, "RIGHT", 10, 0)
    detail.whisper = Button(body, 110, WHISPER or "Whisper")
    detail.whisper:SetPoint("BOTTOMRIGHT", 0, 0)
    detail.whisper:SetScript("OnClick", function()
        local tell = ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
        if ns.selected and tell then tell(ns.selected) end
    end)

    -- Filters.
    local search = Edit(browse, 120, false, 30)
    search:SetPoint("TOPLEFT", RIGHT_X + 8, TOP)
    search:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        filterText = self:GetText()
        ns.UpdateWindow()
    end)
    local hint = Label(search, SEARCH or "Search", "GameFontDisable")
    hint:SetPoint("LEFT", 2, 0)
    search:HookScript("OnEditFocusGained", function() hint:Hide() end)
    search:HookScript("OnEditFocusLost", function(self) hint:SetShown(self:GetText() == "") end)

    frame.readyOnly = Check(browse, L["Ready Only"], function() return ns.db.readyOnly end, function(value) ns.db.readyOnly = value end)
    frame.readyOnly:SetPoint("LEFT", search, "RIGHT", 8, 0)
    frame.dest = Button(browse, 150)
    frame.dest:SetPoint("LEFT", search, "RIGHT", 8, 0)
    frame.dest:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame.dest:SetScript("OnClick", function(_, mouse)
        local list = Destinations()
        local current = 1
        for index, id in ipairs(list) do
            if id == ns.db.dest then current = index end
        end
        ns.db.dest = list[(current - 1 + (mouse == "RightButton" and -1 or 1)) % #list + 1]
        ns.UpdateWindow()
    end)

    local coin = Label(browse, "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t")
    coin:SetPoint("TOPRIGHT", -16, TOP - 4)
    frame.maxFee = Edit(browse, 46, true, 4)
    frame.maxFee:SetPoint("RIGHT", coin, "LEFT", -3, 0)
    frame.maxFee:SetScript("OnTextChanged", function(self, user)
        if not user then return end
        ns.db.maxFee = (tonumber(self:GetText()) or 0) * 10000
        ns.UpdateWindow()
    end)
    local maxLabel = Label(browse, L["Max Fee"])
    maxLabel:SetPoint("RIGHT", frame.maxFee, "LEFT", -10, 0)

    frame.headers = {}
    for column, col in ipairs(COLS) do
        local header = CreateFrame("Button", nil, browse)
        header:SetSize(col.w, 20)
        header:SetPoint("TOPLEFT", RIGHT_X + col.x, TOP - 28)
        local text = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        text:SetAllPoints()
        text:SetJustifyH(col.justify)
        text:SetWordWrap(false)
        header:SetFontString(text)
        header:SetScript("OnClick", function()
            local db, kind = ns.db, ns.db.view
            if db.sort[kind] == col.key then db.sortDown[kind] = not db.sortDown[kind] else db.sort[kind], db.sortDown[kind] = col.key, false end
            ns.UpdateWindow()
        end)
        frame.headers[column] = header
    end

    local scroll = CreateFrame("ScrollFrame", "WormholeScroll", browse, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", RIGHT_X, TOP - 50)
    scroll:SetPoint("BOTTOMRIGHT", -34, 36)
    frame.content = CreateFrame("Frame", nil, scroll)
    frame.content:SetSize(420, 1)
    scroll:SetScrollChild(frame.content)
    frame.none = Label(browse, L["No Offers"], "GameFontDisable")
    frame.none:SetPoint("TOP", scroll, "TOP", 0, -40)

    frame.count = Label(browse, "", "GameFontHighlight")
    frame.count:SetPoint("BOTTOMLEFT", RIGHT_X + 4, 13)
end

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
        char.kind = roles[current % #roles + 1]
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
    local X = 486
    panel.requests = Button(panel, 170)
    panel.requests:SetPoint("TOPLEFT", X, 0)
    panel.requests:SetScript("OnClick", function() ns.ShowRequests() end)
    panel.autoInvite = Check(panel, L["Auto Invite"], function() return char.autoInvite end, function(value) char.autoInvite = value end)
    panel.autoInvite:SetPoint("TOPLEFT", X, -34)
    panel.autoClickers = Check(panel, L["Auto Invite Clickers"], function() return char.autoClickers end, function(value) char.autoClickers = value end)
    panel.autoClickers:SetPoint("TOPLEFT", X, -60)

    panel.test = Check(panel, L["Test Mode"], function() return ns.testMode end, ns.SetTestMode)
    panel.test:SetPoint("BOTTOMLEFT", 0, 0)
    panel.test:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Test Mode"], 1, 1, 1)
        GameTooltip:AddLine(L["Act as any service. Only other testers see your offer."], 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    panel.test:SetScript("OnLeave", GameTooltip_Hide)
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

    frame.tabs = {}
    for index, kind in ipairs({ "S", "P" }) do
        local button = Button(frame, 130, ns.KindName(kind))
        button:SetPoint("TOPLEFT", 14 + (index - 1) * 134, -30)
        button:SetScript("OnClick", function()
            offerMode = false
            if ns.db.view ~= kind then ns.selected = nil end
            ns.db.view = kind
            ns.UpdateWindow()
        end)
        frame.tabs[index] = button
    end
    frame.mine = Button(frame, 130, L["My Offer"])
    frame.mine:SetPoint("TOPRIGHT", -14, -30)
    frame.mine:SetScript("OnClick", function()
        offerMode = true
        ns.UpdateWindow()
    end)
    frame.own = Label(frame, "", "GameFontHighlight")
    frame.own:SetPoint("RIGHT", frame.mine, "LEFT", -12, 0)

    BuildBrowse(frame)
    BuildOffer(frame)

    local options = Button(frame, 100, GAMEMENU_OPTIONS or "Options")
    options:SetHeight(22)
    options:SetPoint("BOTTOMRIGHT", -12, 7)
    options:SetScript("OnClick", function() if ns.OpenOptions then ns.OpenOptions() end end)
    frame.net = Label(frame, "", "GameFontHighlight")
    frame.net:SetPoint("BOTTOMLEFT", 16, 13)

    frame:SetScript("OnShow", function()
        if not frame.map.mapID or not frame.opened then
            frame.opened = true
            if not ns.Map.Go(frame.map, ns.HomeMap()) then ns.Map.Go(frame.map, ns.RootMap()) end
        end
        ns.Tick()
        if ns.net.joined then ns.Query() end
        ns.UpdateWindow()
    end)
    frame:Hide()
    return frame
end

function ns.WindowShown()
    return window ~= nil and window:IsShown()
end

function ns.ToggleWindow(mine)
    if not window then
        local ok, result = pcall(Build)
        if not ok then return ns.Print(tostring(result)) end
        window = result
    end
    if mine then
        offerMode = true
        window:Show()
        ns.UpdateWindow()
    else
        window:SetShown(not window:IsShown())
    end
end
