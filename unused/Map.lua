local _, ns = ...

-- A map of our own, drawn from the game's map tiles. Nothing touches the world map frame.
local Map = {}
ns.Map = Map

local function CursorXY(frame)
    local cx, cy = GetCursorPosition()
    local scale = frame:GetEffectiveScale()
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left then return end
    return (cx / scale - left) / frame:GetWidth(), (top - cy / scale) / frame:GetHeight()
end

local function HasArt(map)
    local layers = map and map ~= 0 and C_Map.GetMapArtLayers(map)
    return layers and layers[1] ~= nil
end

function Map.ParentOf(map)
    local info = C_Map.GetMapInfo(map)
    local parent = info and info.parentMapID
    local up = parent and parent ~= 0 and C_Map.GetMapInfo(parent)
    if up and up.mapType >= 1 and HasArt(parent) then return parent end
end

-- Explored areas are separate textures laid over the base art.
local function DrawExplored(view, map, layer)
    local explored = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures and C_MapExplorationInfo.GetExploredMapTextures(map)
    local used = 0
    local tileW, tileH = layer.tileWidth, layer.tileHeight
    for _, info in ipairs(explored or {}) do
        local wide, tall = math.ceil(info.textureWidth / tileW), math.ceil(info.textureHeight / tileH)
        for row = 1, tall do
            local pixelH, fileH = tileH, tileH
            if row == tall then
                pixelH = info.textureHeight % tileH
                if pixelH == 0 then pixelH = tileH end
                fileH = 16
                while fileH < pixelH do fileH = fileH * 2 end
            end
            for col = 1, wide do
                local pixelW, fileW = tileW, tileW
                if col == wide then
                    pixelW = info.textureWidth % tileW
                    if pixelW == 0 then pixelW = tileW end
                    fileW = 16
                    while fileW < pixelW do fileW = fileW * 2 end
                end
                used = used + 1
                local tex = view.explored[used] or view.canvas:CreateTexture(nil, "ARTWORK")
                view.explored[used] = tex
                tex:ClearAllPoints()
                tex:SetSize(pixelW, pixelH)
                tex:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                tex:SetPoint("TOPLEFT", info.offsetX + tileW * (col - 1), -(info.offsetY + tileH * (row - 1)))
                tex:SetTexture(info.fileDataIDs[(row - 1) * wide + col])
                tex:Show()
            end
        end
    end
    return used
end

local function Draw(view)
    local map = view.mapID
    local layer = C_Map.GetMapArtLayers(map)[1]
    local textures = C_Map.GetMapArtLayerTextures(map, 1) or {}
    local cols = math.ceil(layer.layerWidth / layer.tileWidth)
    view.canvas:SetSize(layer.layerWidth, layer.layerHeight)
    view.canvas:SetScale(view:GetWidth() / layer.layerWidth)
    for index, file in ipairs(textures) do
        local tex = view.tiles[index] or view.canvas:CreateTexture(nil, "BACKGROUND")
        view.tiles[index] = tex
        tex:ClearAllPoints()
        tex:SetSize(layer.tileWidth, layer.tileHeight)
        tex:SetPoint("TOPLEFT", ((index - 1) % cols) * layer.tileWidth, -math.floor((index - 1) / cols) * layer.tileHeight)
        tex:SetTexture(file)
        tex:Show()
    end
    for index = #textures + 1, #view.tiles do view.tiles[index]:Hide() end
    local ok, used = pcall(DrawExplored, view, map, layer)
    for index = (ok and used or 0) + 1, #view.explored do view.explored[index]:Hide() end
end

function Map.Go(view, map)
    if not HasArt(map) then return false end
    view.mapID = map
    Draw(view)
    if view.onChange then view.onChange(map) end
    return true
end

local function Badge(view, index)
    local badge = view.badges[index]
    if badge then return badge end
    badge = CreateFrame("Button", nil, view.overlay)
    badge:SetSize(20, 16)
    local edge = badge:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    edge:SetColorTexture(1, 0.82, 0, 1)
    local fill = badge:CreateTexture(nil, "BORDER")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    fill:SetColorTexture(0.05, 0.05, 0.05, 0.92)
    badge.text = badge:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    badge.text:SetPoint("CENTER")
    badge:SetScript("OnClick", function(self) Map.Go(view, self.map) end)
    badge:SetScript("OnEnter", function(self)
        fill:SetColorTexture(0.3, 0.25, 0, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.MapName(self.map), 1, 1, 1)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function()
        fill:SetColorTexture(0.05, 0.05, 0.05, 0.92)
        GameTooltip:Hide()
    end)
    view.badges[index] = badge
    return badge
end

local function Pin(view, index)
    local pin = view.pins[index]
    if pin then return pin end
    pin = CreateFrame("Button", nil, view.overlay)
    pin.edge = pin:CreateTexture(nil, "BACKGROUND")
    pin.edge:SetAllPoints()
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetPoint("TOPLEFT", 2, -2)
    pin.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pin:SetScript("OnClick", function(self) ns.Select(self.offer.name) end)
    pin:SetScript("OnEnter", function(self) ns.OfferTooltip(self, self.offer) end)
    pin:SetScript("OnLeave", GameTooltip_Hide)
    view.pins[index] = pin
    return pin
end

-- offers: every offer of the shown kind, in list order. Returns pins shown and offers on this very map.
function Map.Update(view, offers, selected, cap)
    local map = view.mapID
    if not map then return 0, 0 end
    local width, height = view:GetWidth(), view:GetHeight()
    local counts, order, here = {}, {}, {}
    for _, offer in ipairs(offers) do
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
    view.counts = counts

    local used = 0
    for _, child in ipairs(order) do
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, child, map)
        if ok and minX and maxX and (maxX > minX or maxY > minY) then
            used = used + 1
            local badge = Badge(view, used)
            badge.map = child
            badge.text:SetText(counts[child])
            badge:SetWidth(math.max(20, badge.text:GetStringWidth() + 8))
            badge:ClearAllPoints()
            badge:SetPoint("CENTER", view.overlay, "TOPLEFT", (minX + maxX) / 2 * width, -(minY + maxY) / 2 * height)
            badge:Show()
        end
    end
    for index = used + 1, #view.badges do view.badges[index]:Hide() end

    local shown = math.min(#here, cap)
    for index = 1, shown do
        local offer = here[index]
        local pin = Pin(view, index)
        local picked = offer.name == selected
        local size = picked and 28 or 20
        pin.offer = offer
        pin:SetSize(size, size)
        pin:SetFrameLevel(view.overlay:GetFrameLevel() + (picked and 3 or 1))
        pin.icon:SetTexture(offer.kind == "S" and ns.SpellIcon(ns.SUMMON_SPELL) or offer.kind == "P" and ns.SpellIcon(offer.dests[1]) or ns.KIND_ICON.C)
        local request = ns.outgoing[offer.name]
        if picked then pin.edge:SetColorTexture(1, 1, 1, 1)
        elseif request and request.state ~= "DECLINED" then pin.edge:SetColorTexture(0.3, 0.8, 1, 1)
        elseif offer.kind == "S" and (offer.ready or 0) >= 2 then pin.edge:SetColorTexture(0.25, 1, 0.25, 1)
        else pin.edge:SetColorTexture(1, 0.82, 0, 1) end
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", view.overlay, "TOPLEFT", offer.x * width, -offer.y * height)
        pin:Show()
    end
    for index = shown + 1, #view.pins do view.pins[index]:Hide() end

    local playerMap, x, y = ns.PlayerPos()
    if playerMap == map then
        view.player:ClearAllPoints()
        view.player:SetPoint("CENTER", view.overlay, "TOPLEFT", x * width, -y * height)
        view.player:Show()
    else
        view.player:Hide()
    end
    return shown, #here
end

local function Hover(view)
    if not view.mapID or not view:IsMouseOver() then
        view.hover:SetText("")
        return
    end
    local x, y = CursorXY(view)
    local info = x and x >= 0 and x <= 1 and y >= 0 and y <= 1 and C_Map.GetMapInfoAtPosition(view.mapID, x, y)
    if info and info.mapID ~= view.mapID then
        local count = view.counts and view.counts[info.mapID]
        view.hover:SetText(count and ("%s  |cffffd100%d|r"):format(info.name, count) or info.name)
        view.hoverMap = info.mapID
    else
        view.hover:SetText("")
        view.hoverMap = nil
    end
end

function Map.Create(parent, width, height)
    local view = CreateFrame("Frame", nil, parent)
    view:SetSize(width, height)
    view:SetClipsChildren(true)
    view.tiles, view.explored, view.badges, view.pins = {}, {}, {}, {}
    local back = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 1)
    view.canvas = CreateFrame("Frame", nil, view)
    view.canvas:SetPoint("TOPLEFT")
    view.overlay = CreateFrame("Frame", nil, view)
    view.overlay:SetAllPoints()
    view.overlay:SetFrameLevel(view.canvas:GetFrameLevel() + 5)
    view.hover = view.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    view.hover:SetPoint("TOP", 0, -6)
    view.player = view.overlay:CreateTexture(nil, "OVERLAY")
    view.player:SetSize(8, 8)
    view.player:SetColorTexture(0.2, 0.6, 1, 1)
    view.player:Hide()

    view:EnableMouse(true)
    view:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            local parent = Map.ParentOf(self.mapID)
            if parent then Map.Go(self, parent) end
        elseif self.hoverMap then
            Map.Go(self, self.hoverMap)
        end
    end)
    local elapsed = 0
    view:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta
        if elapsed < 0.08 then return end
        elapsed = 0
        Hover(self)
    end)
    return view
end
