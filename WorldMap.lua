local _, ns = ...
local L = ns.L

-- Wormhole inside the game's world map: a side tab on the quest log panel with the offer list, and
-- offers drawn on the map while that tab is selected.
--
-- The world map is touchy on this client (its gamepad interface runs the map's Lua from secure code), so:
--   * nothing is added to the map's own pin pools, data providers or overlay lists; the pins are plain frames
--     of ours parented to the canvas, made without a parent first
--   * no frame under the map gets OnShow, OnHide or a click script; a ticker of ours watches the map instead
--   * pins and zone markers carry no click script (the gamepad interface reads such a frame as a button of
--     the window); a click is a press and release over the hovered marker, heard through the global mouse events
--   * nothing is moved or built in combat
-- When ForeverCore is installed its shared tab column is used, so the tab lines up with the other addons' tabs.

local ROW_H = 22
local ROWS = 100
local GREEN, GREY, GOLD, RED, ORANGE = "|cff40ff40", "|cff808080", "|cffffd100", "|cffff4040", "|cffff9040"

local panel, tab, layer
local pins, badges, rows = {}, {}, {}
local active = false
local picked = false       -- own tab selected (path without ForeverCore)
local seen = ""
local drawn = 0
local mapStale, uncleared = false, false   -- combat held back a draw or a clear; done once it ends

local function Combat()
    return InCombatLockdown and InCombatLockdown()
end

function ns.WorldMapActive()
    return active
end

-- Map drawing ----------------------------------------------------------------

local function Tip(self)
    if self.offer then
        ns.OfferTooltip(self, self.offer)
    elseif self.map then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.MapName(self.map), 1, 1, 1)
        GameTooltip:AddLine(("%s: %d"):format(L["Offers"], self.count or 0), 1, 0.82, 0)
        GameTooltip:Show()
    end
end

local hovered, pressed

-- An offer pin or a zone marker: icon and thin border cut to a circle, the zone's count in the corner.
local function Marker(list, index)
    local marker = list[index]
    if marker then return marker end
    marker = CreateFrame("Frame")
    marker:SetParent(layer)
    marker.edge = marker:CreateTexture(nil, "BACKGROUND")
    marker.edge:SetAllPoints()
    marker.icon = marker:CreateTexture(nil, "ARTWORK")
    marker.icon:SetPoint("TOPLEFT", 1, -1)
    marker.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    marker.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pcall(function()
        for _, texture in ipairs({ marker.edge, marker.icon }) do
            local mask = marker:CreateMaskTexture()
            mask:SetAllPoints(texture)
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            texture:AddMaskTexture(mask)
        end
    end)
    marker.text = marker:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    marker.text:SetPoint("BOTTOMRIGHT", 7, -5)
    marker:EnableMouse(true)
    if marker.SetPropagateMouseClicks then pcall(marker.SetPropagateMouseClicks, marker, true) end
    marker:SetScript("OnEnter", function(self)
        hovered = self
        Tip(self)
    end)
    marker:SetScript("OnLeave", function(self)
        if hovered == self then hovered = nil end
        GameTooltip:Hide()
    end)
    list[index] = marker
    return marker
end

local function EnsureLayer()
    if layer then return true end
    if Combat() then return false end
    local canvas = WorldMapFrame:GetCanvas()
    if not canvas then return false end
    layer = CreateFrame("Frame")
    layer:SetParent(canvas)
    layer:SetAllPoints(canvas)
    local level = canvas:GetFrameLevel() + 600
    pcall(function()
        level = WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_AREA_POI") or level
    end)
    layer:SetFrameLevel(level)
    return true
end

local function Filter()
    local db = ns.db
    return { readyOnly = db.readyOnly, maxFee = db.maxFee, dest = db.dest }
end

local function Place(marker, x, y, width, height, zoom)
    -- A constant size on screen whatever the zoom; offsets are in the marker's own scale.
    marker:SetScale(1 / zoom)
    marker:ClearAllPoints()
    marker:SetPoint("CENTER", layer, "TOPLEFT", x * width * zoom, -y * height * zoom)
    marker:Show()
end

local function DrawMap()
    if Combat() or not EnsureLayer() then return end
    local map = WorldMapFrame:GetMapID()
    local width, height = layer:GetWidth(), layer:GetHeight()
    local zoom = WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale() or 1
    if not map or not width or width == 0 or not zoom or zoom == 0 then return end
    local db = ns.db
    local kind = db.view
    local counts, order, here = {}, {}, {}
    for _, offer in ipairs(ns.List(kind, nil, Filter(), db.sort[kind], db.sortDown[kind])) do
        if offer.map == map then
            here[#here + 1] = offer
        else
            local child = ns.ChildToward(offer.map, map)
            if child then
                if not counts[child] then order[#order + 1] = child end
                counts[child] = (counts[child] or 0) + 1
            end
        end
    end
    local used = 0
    for _, child in ipairs(order) do
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, child, map)
        if ok and minX and maxX and (maxX > minX or maxY > minY) then
            used = used + 1
            local badge = Marker(badges, used)
            badge.map, badge.count, badge.offer = child, counts[child], nil
            badge.icon:SetTexture(kind == "S" and ns.SpellIcon(ns.SUMMON_SPELL) or ns.KIND_ICON.P)
            badge.edge:SetColorTexture(1, 0.82, 0, 1)
            badge.text:SetText(counts[child])
            badge:SetSize(16, 16)
            Place(badge, (minX + maxX) / 2, (minY + maxY) / 2, width, height, zoom)
        end
    end
    for index = used + 1, #badges do badges[index]:Hide() end

    local shown = math.min(#here, db.pinCap)
    for index = 1, shown do
        local offer = here[index]
        local pin = Marker(pins, index)
        local chosen = offer.name == ns.selected
        local request = ns.outgoing[offer.name]
        pin.offer = offer
        pin.text:SetText("")
        pin:SetSize(chosen and 20 or 14, chosen and 20 or 14)
        pin.icon:SetTexture(offer.kind == "S" and ns.SpellIcon(ns.SUMMON_SPELL) or ns.SpellIcon(offer.dests[1]))
        if chosen then pin.edge:SetColorTexture(1, 1, 1, 1)
        elseif request and request.state ~= "DECLINED" then pin.edge:SetColorTexture(0.3, 0.8, 1, 1)
        elseif offer.kind == "S" and (offer.ready or 0) >= 2 then pin.edge:SetColorTexture(0.25, 1, 0.25, 1)
        else pin.edge:SetColorTexture(1, 0.82, 0, 1) end
        Place(pin, offer.x, offer.y, width, height, zoom)
    end
    for index = shown + 1, #pins do pins[index]:Hide() end
    return true
end

local function ClearMap()
    if Combat() then return false end
    for _, list in ipairs({ pins, badges }) do
        for _, marker in ipairs(list) do marker:Hide() end
    end
    return true
end

-- A left click on the hovered pin selects its offer in the side panel. Zone markers let the click through to
-- the map below, which opens the zone.
local function OnMouse(_, event, button)
    if button ~= "LeftButton" then return end
    if event == "GLOBAL_MOUSE_DOWN" then
        pressed = active and hovered or nil
    else
        local marker = pressed
        pressed = nil
        if not (marker and marker == hovered and active and marker.offer and marker:IsMouseOver()) then return end
        ns.selected = marker.offer.name
        seen = ""
        ns.Refresh()
    end
end

-- Side panel -----------------------------------------------------------------

local function Destinations()
    local seenIds, list = {}, {}
    for _, offer in pairs(ns.offers) do
        for _, id in ipairs(offer.kind == "P" and offer.dests or {}) do
            if not seenIds[id] then
                seenIds[id] = true
                list[#list + 1] = id
            end
        end
    end
    table.sort(list)
    return list
end

-- Sort and filters in one menu.
local function FilterMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local db = ns.db
    local kind = db.view
    local function Changed()
        seen = ""
        ns.Refresh()
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L["Sort"])
        local sorts = { { "fee", L["Fee"] }, { "name", NAME or "Name" }, { "dist", L["Distance"] }, { "status", kind == "S" and L["Clickers"] or L["Portals"] } }
        for _, item in ipairs(sorts) do
            root:CreateRadio(item[2], function() return db.sort[kind] == item[1] end, function()
                db.sort[kind], db.sortDown[kind] = item[1], false
                Changed()
            end)
        end
        root:CreateDivider()
        root:CreateTitle(L["Max Fee"])
        for _, gold in ipairs({ 0, 1, 2, 5, 10, 20 }) do
            root:CreateRadio(gold == 0 and L["Any"] or GetMoneyString(gold * 10000), function() return db.maxFee == gold * 10000 end, function()
                db.maxFee = gold * 10000
                Changed()
            end)
        end
        root:CreateDivider()
        if kind == "S" then
            root:CreateCheckbox(L["Ready Only"], function() return db.readyOnly end, function()
                db.readyOnly = not db.readyOnly
                Changed()
            end)
        else
            root:CreateTitle(L["Destinations"])
            root:CreateRadio(L["Any Destination"], function() return db.dest == 0 end, function()
                db.dest = 0
                Changed()
            end)
            for _, id in ipairs(Destinations()) do
                root:CreateRadio(ns.PortalName(id), function() return db.dest == id end, function()
                    db.dest = id
                    Changed()
                end)
            end
        end
    end)
end

local function StatusText(offer)
    if offer.kind == "S" then
        if (offer.ready or 0) >= 2 then return GREEN .. L["Ready"] .. "|r" end
        return ("%s%d/2|r"):format(ORANGE, offer.ready or 0)
    end
    local icons = {}
    for index, id in ipairs(offer.dests) do
        if index <= 3 then icons[index] = ("|T%s:14|t"):format(tostring(ns.SpellIcon(id))) end
    end
    return table.concat(icons, " ")
end

local function Row(index)
    local row = rows[index]
    if row then return row end
    row = CreateFrame("Button", nil, panel.content)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)
    row:SetPoint("RIGHT")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.requested = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.requested:SetAllPoints()
    row.requested:SetColorTexture(0.3, 0.8, 1, 0.22)
    row.picked = row:CreateTexture(nil, "BACKGROUND")
    row.picked:SetAllPoints()
    row.picked:SetColorTexture(1, 0.82, 0, 0.18)
    row.fee = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.fee:SetPoint("RIGHT", -4, 0)
    row.fee:SetWidth(64)
    row.fee:SetJustifyH("RIGHT")
    row.status = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.status:SetPoint("RIGHT", row.fee, "LEFT", -4, 0)
    row.status:SetWidth(58)
    row.status:SetJustifyH("LEFT")
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetPoint("LEFT", 4, 0)
    row.label:SetPoint("RIGHT", row.status, "LEFT", -4, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then return ns.OfferMenu(self, self.offer) end
        ns.selected = self.offer.name
        seen = ""
        ns.Refresh()
    end)
    row:SetScript("OnEnter", function(self) ns.OfferTooltip(self, self.offer) end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    rows[index] = row
    return row
end

local function DrawPanel()
    local db = ns.db
    local kind = db.view
    local map = WorldMapFrame:GetMapID()
    panel.kinds.S:SetEnabled(kind ~= "S")
    panel.kinds.P:SetEnabled(kind ~= "P")
    local scope = map and map ~= ns.RootMap() and map or nil
    local list = ns.List(kind, scope, Filter(), db.sort[kind], db.sortDown[kind])
    local count = #list > ROWS and ("%d/%d"):format(ROWS, #list) or tostring(#list)
    panel.zone:SetText(("%s: %s%s|r"):format(map and ns.MapName(map) or "", GOLD, count))
    local status, r, g, b = ns.NetStatus()
    panel.net:SetText(status)
    panel.net:SetTextColor(r, g, b)
    local shown = math.min(#list, ROWS)
    for index = 1, shown do
        local offer = list[index]
        local row = Row(index)
        local request = ns.outgoing[offer.name]
        row.offer = offer
        row.label:SetText(offer.own and (GREEN .. offer.name .. "|r") or offer.name)
        row.status:SetText(StatusText(offer))
        row.fee:SetText(ns.Money(offer.fee))
        row.picked:SetShown(offer.name == ns.selected)
        row.requested:SetShown(request ~= nil and request.state ~= "DECLINED")
        row:Show()
    end
    for index = shown + 1, #rows do rows[index]:Hide() end
    panel.content:SetHeight(math.max(shown * ROW_H, 1))
    panel.none:SetShown(#list == 0)

    local offer = ns.selected and ns.offers[ns.selected]
    if offer and offer.kind ~= kind then offer = nil end
    panel.detail:SetShown(offer ~= nil)
    panel.prompt:SetShown(offer == nil)
    -- The detail area is as tall as its buttons need; the list takes the rest.
    if not offer then
        panel.detail:SetHeight(60)
        return
    end
    panel.name:SetText(offer.name)
    panel.where:SetText(("%s (%d, %d)"):format(ns.MapName(offer.map), offer.x * 100, offer.y * 100))
    panel.note:SetText(offer.note or "")
    local request = ns.outgoing[offer.name]
    local pending = request and request.state == "SENT"
    local state = not request and "" or request.state == "ACCEPTED" and (GREEN .. L["Accepted"] .. "|r")
        or request.state == "DECLINED" and (RED .. L["Declined"] .. "|r") or (GOLD .. L["Requested"] .. "|r")
    if request and request.kind == "P" and request.state ~= "DECLINED" then state = ("%s: %s"):format(state, ns.PortalName(request.arg)) end
    panel.state:SetText(state)
    -- A portal offer has one button per city: clicking a city requests that portal.
    local free = not offer.own and ns.OpenRequests() < ns.REQUEST_MAX and ns.CanRequest(offer.name)
    local dests = offer.kind == "P" and not pending and offer.dests or {}
    panel.ask:SetShown(#dests > 0)
    for index, button in ipairs(panel.dests) do
        local id = dests[index]
        button:SetShown(id ~= nil)
        if id then
            button.id = id
            button:SetText(("|T%s:16|t %s"):format(tostring(ns.SpellIcon(id)), ns.PortalName(id)))
            button:SetEnabled(free)
        end
    end
    panel.detail:SetHeight(78 + math.max(1, math.ceil(#dests / 2)) * 24)
    panel.request:SetShown(offer.kind == "S" or pending)
    panel.request:SetText(pending and L["Cancel Request"] or L["Request Summon"])
    panel.request:SetEnabled(pending or free)
end

local function BuildPanel()
    local f = CreateFrame("Frame")
    f:SetParent(QuestMapFrame)
    f:SetAllPoints(QuestMapFrame)
    f:SetFrameLevel(QuestMapFrame:GetFrameLevel() + 20)
    f:EnableMouse(true)
    local back = f:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0.04, 0.04, 0.04, 0.96)

    local function Button(parent, text)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetHeight(22)
        button:SetText(text or "")
        return button
    end

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("Wormhole")
    f.net = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.net:SetPoint("TOPRIGHT", -12, -14)

    f.kinds = {}
    f.kinds.S = Button(f, ns.KindName("S"))
    f.kinds.S:SetPoint("TOPLEFT", 10, -38)
    f.kinds.S:SetPoint("RIGHT", f, "CENTER", -2, 0)
    f.kinds.P = Button(f, ns.KindName("P"))
    f.kinds.P:SetPoint("TOPRIGHT", -10, -38)
    f.kinds.P:SetPoint("LEFT", f, "CENTER", 2, 0)
    for kind, button in pairs(f.kinds) do
        button:SetScript("OnClick", function()
            if ns.db.view ~= kind then ns.selected = nil end
            ns.db.view = kind
            seen = ""
            ns.Refresh()
        end)
    end
    f.zone = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.zone:SetPoint("TOPLEFT", 12, -70)
    f.filter = Button(f, L["Filter"])
    f.filter:SetWidth(100)
    f.filter:SetPoint("TOPRIGHT", -10, -64)
    f.filter:SetScript("OnClick", function(self) FilterMenu(self) end)

    -- Selected offer.
    local detail = CreateFrame("Frame", nil, f)
    detail:SetPoint("BOTTOMLEFT", 10, 40)
    detail:SetPoint("BOTTOMRIGHT", -10, 40)
    detail:SetHeight(152)
    f.detail = detail
    f.prompt = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    f.prompt:SetPoint("CENTER", detail, "CENTER")
    f.prompt:SetText(L["Select an Offer"])
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT", detail, "TOPLEFT", 0, 4)
    line:SetPoint("BOTTOMRIGHT", detail, "TOPRIGHT", 0, 4)
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, 0.15)
    f.name = detail:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f.name:SetPoint("TOPLEFT", 2, 0)
    f.where = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.where:SetPoint("TOPLEFT", 2, -20)
    f.note = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.note:SetPoint("TOPLEFT", 2, -38)
    f.state = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.state:SetPoint("TOPLEFT", 2, -56)
    f.note:SetPoint("RIGHT", -2, 0)
    f.note:SetJustifyH("LEFT")
    f.note:SetWordWrap(false)
    f.note:SetTextColor(0.8, 0.8, 0.8)
    f.request = Button(detail)
    f.request:SetPoint("TOPLEFT", 0, -78)
    f.request:SetPoint("RIGHT")
    f.request:SetScript("OnClick", function()
        local offer = ns.selected and ns.offers[ns.selected]
        if not offer then return end
        local request = ns.outgoing[offer.name]
        if request and request.state == "SENT" then ns.Cancel(offer.name) elseif offer.kind == "S" then ns.Request(offer.name, "S") end
        seen = ""
    end)
    f.ask = detail:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.ask:SetPoint("TOPLEFT", 2, -60)
    f.ask:SetText(L["Request Portal"] .. ":")
    f.dests = {}
    for index = 1, 6 do
        local button = Button(detail)
        local y = -78 - math.floor((index - 1) / 2) * 24
        if index % 2 == 1 then
            button:SetPoint("TOPLEFT", 0, y)
            button:SetPoint("RIGHT", detail, "CENTER", -2, 0)
        else
            button:SetPoint("TOPRIGHT", 0, y)
            button:SetPoint("LEFT", detail, "CENTER", 2, 0)
        end
        button:SetScript("OnClick", function(self)
            if ns.selected then ns.Request(ns.selected, "P", self.id) end
            seen = ""
        end)
        f.dests[index] = button
    end

    local mine = Button(f, L["My Offer"])
    mine:SetPoint("BOTTOMLEFT", 10, 10)
    mine:SetPoint("BOTTOMRIGHT", -10, 10)
    mine:SetScript("OnClick", function() ns.ToggleWindow(true) end)

    local scroll = CreateFrame("ScrollFrame", "WormholeMapScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -92)
    scroll:SetPoint("BOTTOMRIGHT", detail, "TOPRIGHT", -20, 10)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(240, 1)
    scroll:SetScrollChild(f.content)
    f.scroll = scroll
    f.none = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    f.none:SetPoint("TOP", scroll, "TOP", 0, -30)
    f.none:SetText(L["No Offers"])
    -- Until the first draw the panel is an empty list with the prompt, not every control at once.
    f.none:Hide()
    detail:Hide()
    detail:SetHeight(60)
    f.kinds.S:SetEnabled(ns.db.view ~= "S")
    f.kinds.P:SetEnabled(ns.db.view ~= "P")
    f:Hide()
    return f
end

-- Tab ------------------------------------------------------------------------

local function Paint()
    local icon = tab and tab.Icon
    if not icon then return end
    pcall(function()
        icon:SetTexture(ns.KIND_ICON.P)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetSize(26, 26)
    end)
end

-- Without ForeverCore: a tab of our own under the game's, which swaps the quest log's content for the panel.
local function Deselect()
    if not picked then return end
    picked = false
    panel:Hide()
    tab:SetChecked(false)
    for _, frame in ipairs(QuestMapFrame.ContentFrames or {}) do
        frame:SetShown(frame.displayMode == QuestMapFrame.displayMode)
    end
end

local function Select()
    if picked then return Deselect() end
    picked = true
    for _, frame in ipairs(QuestMapFrame.ContentFrames or {}) do frame:Hide() end
    panel:Show()
    tab:SetChecked(true)
end

local function OwnTab()
    tab = CreateFrame("Button", "WormholeMapTab", QuestMapFrame, "LargeSideTabButtonTemplate")
    tab.tooltipText = "Wormhole"
    tab.activeAtlas, tab.inactiveAtlas = "questlog-tab-icon-quest", "questlog-tab-icon-quest-inactive"
    local stock = QuestMapFrame.MapLegendTab and QuestMapFrame.MapLegendTab:IsShown() and QuestMapFrame.MapLegendTab or QuestMapFrame.QuestsTab
    if stock then tab:SetPoint("TOP", stock, "BOTTOM", 0, -3) else tab:SetPoint("TOPLEFT", QuestMapFrame, "TOPRIGHT", 0, -40) end
    if tab.SetCustomOnMouseUpHandler then
        tab:SetCustomOnMouseUpHandler(function(_, button, inside)
            if inside and button == "LeftButton" then Select() end
        end)
    else
        tab:SetScript("OnMouseUp", Select)
    end
    -- Any other way into the quest log puts its own content back.
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("QuestLog.SetDisplayMode", Deselect, tab)
    end
    for _, name in ipairs({ "QuestsTab", "MapLegendTab", "EventsTab" }) do
        local other = QuestMapFrame[name]
        if other and other.HookScript then other:HookScript("OnMouseUp", Deselect) end
    end
end

local function Watch()
    local now = panel:IsShown() and WorldMapFrame:IsShown() and QuestMapFrame:IsShown()
    if now ~= active then
        active = now
        seen = ""
        if active then
            ns.Tick()
            ns.Query()
        else
            uncleared = not ClearMap()
        end
    end
    if not active then
        if uncleared then uncleared = not ClearMap() end
        return
    end
    if mapStale and not Combat() and GetTime() - drawn > 1 then seen = "" end
    local zoom = WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale() or 1
    local stamp = table.concat({ tostring(WorldMapFrame:GetMapID()), tostring(zoom), tostring(layer and layer:GetWidth() or 0), ns.version or 0 }, ":")
    if stamp == seen then return end
    seen = stamp
    drawn = GetTime()
    DrawPanel()
    mapStale = not DrawMap()
end

-- Opens the world map on the Wormhole tab.
function ns.OpenWorldMap()
    if not panel or Combat() then return end
    if not WorldMapFrame:IsShown() and ToggleWorldMap then ToggleWorldMap() end
    if panel:IsShown() or not tab then return end
    local shared = ForeverCore and ForeverCore.QuestLogTabs
    if not picked and type(shared) == "table" and type(shared.Select) == "function" and shared.Selected then
        pcall(shared.Select, "Wormhole")
    elseif tab:GetScript("OnMouseUp") then
        tab:GetScript("OnMouseUp")(tab, "LeftButton")
    end
end

function ns.InitWorldMap()
    if not ns.db.worldMap or not (WorldMapFrame and QuestMapFrame and WorldMapFrame.GetCanvas) then return end
    panel = BuildPanel()
    local shared = ForeverCore and ForeverCore.QuestLogTabs
    local ok = false
    if type(shared) == "table" and type(shared.Register) == "function" then
        ok, tab = pcall(shared.Register, "Wormhole", { name = "WormholeMapTab", tooltip = "Wormhole", panel = panel, order = 90 })
        if ok and tab then
            tab.activeAtlas, tab.inactiveAtlas = "questlog-tab-icon-quest", "questlog-tab-icon-quest-inactive"
            pcall(tab.SetChecked, tab, false)
        end
    end
    if not (ok and tab) then OwnTab() end
    if tab.SetChecked then hooksecurefunc(tab, "SetChecked", Paint) end
    Paint()
    local mouse = CreateFrame("Frame")
    mouse:RegisterEvent("GLOBAL_MOUSE_DOWN")
    mouse:RegisterEvent("GLOBAL_MOUSE_UP")
    mouse:SetScript("OnEvent", OnMouse)
    C_Timer.NewTicker(0.05, function()
        local fine, err = pcall(Watch)
        if not fine and not ns.mapError then
            ns.mapError = true
            ns.Print(tostring(err))
        end
    end)
end
