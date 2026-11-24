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
local picking              -- the next click on the map is a spot: "WANT" for a request, "WATCH" for the watch list
local draft                -- the spot picked for a request not posted yet

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
        GameTooltip:AddLine(("%s: %d"):format(ns.db.view == "W" and L["Requests"] or L["Offers"], self.count or 0), 1, 0.82, 0)
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
    local all = kind == "W" and ns.WantedList() or ns.List(kind, nil, Filter(), db.sort[kind], db.sortDown[kind])
    for _, offer in ipairs(all) do
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
            badge.icon:SetTexture(kind == "S" and ns.SpellIcon(ns.SUMMON_SPELL) or ns.KIND_ICON[kind])
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
        pin.icon:SetTexture(offer.kind == "W" and ns.KIND_ICON.W or offer.kind == "S" and ns.SpellIcon(ns.SUMMON_SPELL)
            or ns.SpellIcon(offer.dests[1]))
        if chosen then pin.edge:SetColorTexture(1, 1, 1, 1)
        elseif offer.kind == "W" then
            -- Blue: the own request or one being taken. Green: one that concerns this account.
            if offer.own or offer.state then pin.edge:SetColorTexture(0.3, 0.8, 1, 1)
            elseif offer.why then pin.edge:SetColorTexture(0.25, 1, 0.25, 1)
            else pin.edge:SetColorTexture(1, 0.82, 0, 1) end
        elseif request and request.state ~= "DECLINED" then pin.edge:SetColorTexture(0.3, 0.8, 1, 1)
        elseif offer.kind == "S" and (offer.ready or 0) >= 2 then pin.edge:SetColorTexture(0.25, 1, 0.25, 1)
        else pin.edge:SetColorTexture(1, 0.82, 0, 1) end
        Place(pin, offer.x, offer.y, width, height, zoom)
    end
    -- The spot picked for a request that is not posted yet.
    if kind == "W" and draft and draft.map == map then
        shown = shown + 1
        local pin = Marker(pins, shown)
        pin.offer, pin.map = nil, nil
        pin.text:SetText("")
        pin:SetSize(20, 20)
        pin.icon:SetTexture(ns.KIND_ICON.W)
        pin.edge:SetColorTexture(1, 1, 1, 1)
        Place(pin, draft.x, draft.y, width, height, zoom)
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
local pressX, pressY
local pressMap, pressNX, pressNY   -- map and spot under the cursor at the press, before the map can react

-- While picking, a plain mouse-enabled frame lies over the map view and swallows the click, so the map below
-- does not open the zone under the cursor. It carries no script; the click is still read from the global events.
local catcher
local function Catch(on)
    if not catcher then
        if not on or Combat() then return end
        local view = WorldMapFrame.ScrollContainer or (WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer())
        if not view then return end
        catcher = CreateFrame("Frame")
        catcher:SetParent(view)
        catcher:SetAllPoints(view)
        catcher:SetFrameLevel(math.min(view:GetFrameLevel() + 2000, 9900))
        catcher:EnableMouse(true)
        if catcher.SetMouseClickEnabled then pcall(catcher.SetMouseClickEnabled, catcher, true) end
        if catcher.SetPropagateMouseClicks then pcall(catcher.SetPropagateMouseClicks, catcher, false) end
        catcher:Hide()
    end
    if catcher:IsShown() ~= on then catcher:SetShown(on) end
end

-- A continent or anything below it; the world map only leads to those.
local function Pickable(map)
    local info = map and C_Map.GetMapInfo(map)
    return info ~= nil and (info.mapType or 0) >= 2
end

local function ZoneMap(map)
    local info = map and C_Map.GetMapInfo(map)
    return info ~= nil and (info.mapType or 0) >= 3
end

local function Cursor()
    local ok, x, y = pcall(WorldMapFrame.GetNormalizedCursorPosition, WorldMapFrame)
    if ok and type(x) == "number" and type(y) == "number" and x > 0 and x < 1 and y > 0 and y < 1 then return x, y end
end

-- The zone a spot lies in and where in it. A click on a continent map, or on a neighbour shown at the edge of
-- a zone map, names the zone under the cursor.
local function Resolve(map, x, y)
    local ok, info = pcall(C_Map.GetMapInfoAtPosition, map, x, y)
    if ok and info and info.mapID and info.mapID ~= map and (info.mapType or 0) >= 3 then
        local fine, zx, zy = pcall(function()
            local continent, world = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x, y))
            local _, pos = C_Map.GetMapPosFromWorldPos(continent, world, info.mapID)
            return pos.x, pos.y
        end)
        if fine and type(zx) == "number" and type(zy) == "number" and zx > 0 and zx < 1 and zy > 0 and zy < 1 then return info.mapID, zx, zy end
    end
    if ZoneMap(map) then return map, x, y end
end

-- While picking, a click on the map is the spot. A drag pans the map and is not one. The spot is the one under
-- the cursor at the press, so it holds even where the map opens a zone on the release.
local function Pick()
    local cx, cy = GetCursorPosition()
    if not pressX or math.abs(cx - pressX) > 6 or math.abs(cy - pressY) > 6 then return end
    if not (pressMap and pressNX) then return end
    local map, x, y = Resolve(pressMap, pressNX, pressNY)
    if not map then return end
    if picking == "WATCH" then
        ns.WatchSpot(map, x, y)
    else
        draft = { map = map, x = x, y = y, area = ns.AreaAt(map, x, y) }
        ns.selected = nil
    end
    picking = nil
    seen = ""
    ns.Refresh()
end

local function OnMouse(_, event, button)
    if button ~= "LeftButton" then return end
    if event == "GLOBAL_MOUSE_DOWN" then
        pressed = active and hovered or nil
        pressX, pressY = GetCursorPosition()
        pressMap, pressNX, pressNY = nil, nil, nil
        local view = WorldMapFrame.ScrollContainer
        if picking and active and not (view and view.IsMouseOver and not view:IsMouseOver()) then
            pressMap = WorldMapFrame:GetMapID()
            pressNX, pressNY = Cursor()
        end
    else
        local marker = pressed
        pressed = nil
        if picking and active then return Pick() end
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

-- Wanted: what to be alerted for. Places are the viewed map's.
local function WatchMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local db = ns.db
    local map = WorldMapFrame:GetMapID()
    local function Changed()
        seen = ""
        ns.Tick()
        ns.Refresh()
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(460) end
        root:CreateTitle(L["Alerts"])
        root:CreateCheckbox(L["Alert Me"], function() return db.watchOn end, function()
            db.watchOn = not db.watchOn
            Changed()
        end)
        root:CreateDivider()
        root:CreateTitle(L["Near My Warlocks"])
        local locks = ns.AllWarlocks()
        if #locks == 0 then
            local none = root:CreateButton(L["Needs a warlock."], function() end)
            if none and none.SetEnabled then none:SetEnabled(false) end
        end
        for _, lock in ipairs(locks) do
            root:CreateCheckbox(lock.name, function() return not ns.WarlockOff(lock.name) end, function()
                ns.SetWarlockOff(lock.name, not ns.WarlockOff(lock.name))
                Changed()
            end)
        end
        for _, range in ipairs(ns.WATCH_RANGES) do
            root:CreateRadio(range == 0 and L["Same Zone"] or ("%d %s"):format(range, L["yd"]), function() return db.watchRange == range end, function()
                db.watchRange = range
                Changed()
            end)
        end
        if map and map ~= ns.RootMap() then
            root:CreateDivider()
            root:CreateTitle(ns.MapName(map))
            root:CreateCheckbox(L["Whole Map"], function() return db.watchZones[map] == true end, function()
                ns.WatchZone(map, not db.watchZones[map])
                seen = ""
            end)
        end
        if ZoneMap(map) then
            for _, place in ipairs(ns.Places(map)) do
                root:CreateCheckbox(place.name, function() return db.watchPlaces[place.key] ~= nil end, function()
                    ns.WatchPlace(place, db.watchPlaces[place.key] == nil)
                    seen = ""
                end)
            end
            -- Spots picked by hand; unticking one drops it.
            local spots = {}
            for key, place in pairs(db.watchPlaces) do
                if key:sub(1, 1) == "X" and place.map == map then spots[#spots + 1] = { key = key, text = ns.Where(place) } end
            end
            table.sort(spots, function(a, b) return a.key < b.key end)
            for _, spot in ipairs(spots) do
                root:CreateCheckbox(spot.text, function() return db.watchPlaces[spot.key] ~= nil end, function()
                    db.watchPlaces[spot.key] = nil
                    Changed()
                end)
            end
            root:CreateButton(L["Pick a Spot"], function()
                picking, draft = "WATCH", nil
                seen = ""
            end)
        end
        root:CreateDivider()
        root:CreateButton(("%s (%d)"):format(L["Clear Watched"], ns.WatchCount()), function()
            ns.ClearWatch()
            seen = ""
        end)
    end)
end

local function StatusText(offer)
    if offer.kind == "W" then
        if offer.dist and offer.dist < 10000 then return ("%d %s"):format(offer.dist, L["yd"]) end
        return ""
    end
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

-- The detail area of the Wanted view: picking a spot, the draft, or the selected request.
local function DrawWanted(map)
    panel.ask:Hide()
    for _, button in ipairs(panel.dests) do button:Hide() end
    if picking then
        panel.detail:Hide()
        panel.prompt:Show()
        panel.prompt:SetText(Pickable(map) and L["Click the map."] or L["Open a zone map."])
        panel.detail:SetHeight(60)
        return
    end
    local entry = not draft and ns.selected and ns.wanted[ns.selected] or nil
    panel.detail:SetShown(draft ~= nil or entry ~= nil)
    panel.prompt:SetShown(not draft and not entry)
    panel.prompt:SetText(L["Select a Request"])
    if not draft and not entry then
        panel.detail:SetHeight(60)
        return
    end
    panel.detail:SetHeight(78 + 24)
    panel.request:Show()
    if draft then
        panel.name:SetText(ns.Where(draft))
        panel.where:SetText(("%s (%d, %d)"):format(ns.MapName(draft.map), draft.x * 100, draft.y * 100))
        panel.note:SetText("")
        panel.state:SetText("")
        panel.request:SetText(L["Post Request"])
        panel.request:SetEnabled(true)
        return
    end
    panel.name:SetText(entry.name)
    panel.where:SetText(ns.Where(entry))
    panel.note:SetText(("%s: %s"):format(L["Reward"], entry.fee > 0 and ns.Money(entry.fee) or "-"))
    if entry.own then
        local taker = entry.taker
        local who = taker and (taker.lock ~= taker.name and ("%s (%s)"):format(taker.name, taker.lock) or taker.name)
        panel.state:SetText(taker and ("%s%s|r: %s"):format(GREEN, L["Accepted"], who) or (GOLD .. L["Open"] .. "|r"))
        panel.request:SetText(L["Cancel Request"])
        panel.request:SetEnabled(true)
        return
    end
    local state = entry.state == "TAKING" and (GOLD .. L["Requested"] .. "|r") or #ns.AllWarlocks() == 0 and (GREY .. L["Needs a warlock."] .. "|r")
        or entry.why and (GREEN .. ns.ReasonText(entry) .. "|r") or ""
    panel.state:SetText(state)
    panel.request:SetText(ACCEPT or "Accept")
    panel.request:SetEnabled(ns.CanTake(entry))
end

local function DrawPanel()
    local db = ns.db
    local kind = db.view
    local map = WorldMapFrame:GetMapID()
    ns.FitBackdrop(panel.art, panel:GetWidth(), panel:GetHeight())
    -- Summoning and Wanted sit together; Portals stands apart behind a gap.
    local third = (panel:GetWidth() - 20 - 2 - 16) / 3
    for name, button in pairs(panel.kinds) do
        if third > 40 then button:SetWidth(third) end
        button:SetEnabled(kind ~= name)
    end
    local wanted = kind == "W"
    panel.filter:SetText(wanted and L["Alerts"] or L["Filter"])
    panel.pick:SetText((picking or draft) and (CANCEL or "Cancel") or L["Pick Destination"])
    -- A destination to pick would read as a portal's; the button belongs to summons only.
    local portals = kind == "P"
    if panel.pick:IsShown() == portals then
        panel.pick:SetShown(not portals)
        panel.mine:ClearAllPoints()
        panel.mine:SetPoint("BOTTOMRIGHT", -10, 10)
        if portals then panel.mine:SetPoint("LEFT", panel, "LEFT", 10, 0) else panel.mine:SetPoint("LEFT", panel, "CENTER", 2, 0) end
    end
    local scope = map and map ~= ns.RootMap() and map or nil
    local list = wanted and ns.WantedList(scope) or ns.List(kind, scope, Filter(), db.sort[kind], db.sortDown[kind])
    local count = #list > ROWS and ("%d/%d"):format(ROWS, #list) or tostring(#list)
    panel.zone:SetText(("%s: %s%s|r"):format(map and ns.MapName(map) or "", GOLD, count))
    local status, r, g, b = ns.NetStatus()
    panel.net:SetText(status)
    panel.net:SetTextColor(r, g, b)
    local shown = math.min(#list, ROWS)
    -- Rows span the list; the scroll child has no width of its own.
    local span = panel.scroll:GetWidth()
    if span and span > 100 then panel.content:SetWidth(span) end
    for index = 1, shown do
        local offer = list[index]
        local row = Row(index)
        local request = ns.outgoing[offer.name]
        row.offer = offer
        if wanted then
            -- The place is what a warlock reads first; who asks is in the detail below.
            row.label:SetText((offer.own and GREEN or offer.why and GOLD or "|cffffffff") .. ns.Where(offer) .. "|r")
            row.fee:SetText(offer.fee > 0 and ns.Money(offer.fee) or "")
            row.requested:SetShown(offer.state == "TAKING")
            -- The place gets whatever the distance and reward do not need.
            row.status:SetWidth(offer.dist and offer.dist < 10000 and 50 or 1)
            row.fee:SetWidth(offer.fee > 0 and 64 or 1)
        else
            row.label:SetText(offer.own and (GREEN .. offer.name .. "|r") or offer.name)
            row.fee:SetText(ns.Money(offer.fee))
            row.requested:SetShown(request ~= nil and request.state ~= "DECLINED")
            row.status:SetWidth(58)
            row.fee:SetWidth(64)
        end
        row.status:SetText(StatusText(offer))
        row.picked:SetShown(offer.name == ns.selected)
        row:Show()
    end
    for index = shown + 1, #rows do rows[index]:Hide() end
    panel.content:SetHeight(math.max(shown * ROW_H, 1))
    panel.none:SetShown(#list == 0)
    panel.none:SetText(wanted and L["No Requests"] or L["No Offers"])
    panel.reward:SetShown(wanted and draft ~= nil and not picking)
    if wanted then return DrawWanted(map) end
    panel.prompt:SetText(L["Select an Offer"])

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
    f.art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.art:SetAllPoints()
    f.art:SetTexture(ns.BACKDROP)
    f.art:SetAlpha(0.9)
    ns.FitBackdrop(f.art, 290, 470)

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
    -- Three across; the width is set at each draw, when the panel has its size.
    f.kinds.S = Button(f, ns.KindName("S"))
    f.kinds.S:SetPoint("TOPLEFT", 10, -38)
    f.kinds.W = Button(f, ns.KindName("W"))
    f.kinds.W:SetPoint("LEFT", f.kinds.S, "RIGHT", 2, 0)
    f.kinds.P = Button(f, ns.KindName("P"))
    f.kinds.P:SetPoint("TOPRIGHT", -10, -38)
    local split = f:CreateTexture(nil, "ARTWORK")
    split:SetSize(1, 18)
    split:SetPoint("RIGHT", f.kinds.P, "LEFT", -8, 0)
    split:SetColorTexture(1, 1, 1, 0.25)
    for kind, button in pairs(f.kinds) do
        button:SetWidth(86)
        button:SetScript("OnClick", function()
            if ns.db.view ~= kind then ns.selected = nil end
            picking, draft = nil, nil
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
    f.filter:SetScript("OnClick", function(self)
        if ns.db.view == "W" then WatchMenu(self) else FilterMenu(self) end
    end)

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
    f.name:SetPoint("RIGHT", -2, 0)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    -- Wanted: what the poster pays the warlock, in gold and silver.
    local reward = CreateFrame("Frame", nil, detail)
    reward:SetPoint("TOPLEFT", 0, -40)
    reward:SetPoint("RIGHT")
    reward:SetHeight(24)
    f.reward = reward
    local rewardLabel = reward:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    rewardLabel:SetPoint("LEFT", 2, 0)
    rewardLabel:SetText(L["Reward"])
    local function Coin(width, letters, icon, after, gap)
        local edit = CreateFrame("EditBox", nil, reward, "InputBoxTemplate")
        edit:SetSize(width, 20)
        edit:SetPoint("LEFT", after, "RIGHT", gap, 0)
        edit:SetAutoFocus(false)
        edit:SetNumeric(true)
        edit:SetMaxLetters(letters)
        edit:SetScript("OnEnterPressed", edit.ClearFocus)
        edit:SetScript("OnEscapePressed", edit.ClearFocus)
        local mark = reward:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        mark:SetPoint("LEFT", edit, "RIGHT", 3, 0)
        mark:SetText(("|TInterface\\MoneyFrame\\UI-%sIcon:14:14|t"):format(icon))
        return edit, mark
    end
    local goldMark, silverMark
    f.gold, goldMark = Coin(34, 2, "Gold", rewardLabel, 14)
    f.silver, silverMark = Coin(28, 2, "Silver", goldMark, 10)
    reward:Hide()
    f.note:SetPoint("RIGHT", -2, 0)
    f.note:SetJustifyH("LEFT")
    f.note:SetWordWrap(false)
    f.note:SetTextColor(0.8, 0.8, 0.8)
    f.request = Button(detail)
    f.request:SetPoint("TOPLEFT", 0, -78)
    f.request:SetPoint("RIGHT")
    f.request:SetScript("OnClick", function()
        if ns.db.view == "W" then
            local entry = ns.selected and ns.wanted[ns.selected]
            if draft then
                ns.PostWant(draft.map, draft.x, draft.y, (tonumber(f.gold:GetText()) or 0) * 10000 + (tonumber(f.silver:GetText()) or 0) * 100)
                draft = nil
                f.gold:ClearFocus()
                f.silver:ClearFocus()
                ns.selected = ns.me
            elseif entry and entry.own then
                ns.CancelWant()
            elseif entry then
                ns.Take(entry.name)
            end
            seen = ""
            return
        end
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

    -- No offer where the player wants to go: mark the spot and ask for a summon there.
    f.pick = Button(f, L["Pick Destination"])
    f.pick:SetPoint("BOTTOMLEFT", 10, 10)
    f.pick:SetPoint("RIGHT", f, "CENTER", -2, 0)
    f.pick:SetScript("OnClick", function()
        if picking or draft then
            picking, draft = nil, nil
        else
            ns.db.view, ns.selected, picking = "W", nil, "WANT"
        end
        seen = ""
        ns.Refresh()
    end)
    local mine = Button(f, L["My Offer"])
    mine:SetPoint("BOTTOMRIGHT", -10, 10)
    mine:SetPoint("LEFT", f, "CENTER", 2, 0)
    mine:SetScript("OnClick", function() ns.ToggleWindow(true) end)
    f.mine = mine

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
    for kind, button in pairs(f.kinds) do button:SetEnabled(ns.db.view ~= kind) end
    f:Hide()
    return f
end

-- Tab ------------------------------------------------------------------------

local function Paint()
    if not tab then return end
    pcall(function()
        local icon = tab.Icon
        -- A tab without an icon slot of its own gets one drawn on top.
        if not icon then
            icon = tab.wormholeIcon or tab:CreateTexture(nil, "OVERLAY")
            tab.wormholeIcon = icon
            icon:SetPoint("CENTER")
        end
        icon:SetTexture(ns.LOGO)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetSize(28, 28)
        if icon.SetDesaturated then icon:SetDesaturated(false) end
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
            picking = nil
            uncleared = not ClearMap()
        end
    end
    Catch(active and picking ~= nil and Pickable(WorldMapFrame:GetMapID()))
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

function ns.WorldMapReady()
    return panel ~= nil
end

function ns.InitWorldMap()
    if panel or Combat() then return end
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
