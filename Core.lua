local ADDON, ns = ...
local L = ns.L

-- Offer kinds: S = warlock summon, P = mage portal, C = clicker for hire.
ns.PORTALS = { 10059, 11416, 11419, 11417, 11418, 11420 }
-- Test mode on a character without portals.
local FACTION_PORTALS = { Alliance = { 10059, 11416, 11419 }, Horde = { 11417, 11418, 11420 } }
ns.SUMMON_SPELL = 698
ns.NOTE_MAX = 60
ns.LOGO = "Interface\\AddOns\\Wormhole\\media\\Icon.tga"
ns.KIND_ICON = {
    S = "Interface\\Icons\\Spell_Shadow_Twilight",
    P = "Interface\\Icons\\Spell_Arcane_PortalStormwind",
    C = "Interface\\Icons\\INV_Misc_Coin_02",
}

ns.defaults = {
    view = "S",
    autoAfk = true,
    autoInstance = true,
    pinCap = 30,
    sound = true,
    autoOpen = false,
    orbShow = true,
    orbScale = 1,
    alertChat = true,
    alertScreen = true,
    worldMap = true,
    minimapShow = true,
    minimapAngle = 200,
    readyOnly = false,
    maxFee = 0,
    dest = 0,
    sort = { S = "fee", P = "fee" },
    sortDown = { S = false, P = false },
}
ns.charDefaults = {
    active = false,
    fee = { S = 0, P = 0, C = 0 },
    note = "",
    clickerPay = 0,
    range = 300,
    autoInvite = false,
    autoClickers = true,
    portalsOff = {},
}

ns.offers = {}
ns.me = ""

function ns.Print(msg)
    print("|cffffd100Wormhole|r: " .. msg)
end

function ns.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper <= 0 then return L["Free"] end
    return GetMoneyString(copper)
end

function ns.ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            ns.ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

-- Spells -------------------------------------------------------------------

function ns.SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

function ns.SpellIcon(id)
    local icon
    if C_Spell and C_Spell.GetSpellTexture then icon = C_Spell.GetSpellTexture(id)
    elseif GetSpellTexture then icon = GetSpellTexture(id) end
    return icon or 134400
end

function ns.PortalName(id)
    local name = ns.SpellName(id)
    if not name then return "?" end
    return name:match(":%s*(.+)$") or name
end

local function Known(id)
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    return IsSpellKnown and IsSpellKnown(id) or false
end

local function ScanSpellbook(visit)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    if item and item.spellID and not item.isPassive then visit(item.spellID, item.name) end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, count = GetSpellTabInfo(tab)
            for slot = offset + 1, offset + count do
                local kind, id = GetSpellBookItemInfo(slot, "spell")
                if kind == "SPELL" and id then visit(id, GetSpellBookItemName(slot, "spell")) end
            end
        end
    end
end

-- Known portals: the classic six, plus any spellbook spell sharing their localized "Portal:" prefix,
-- so portals this game adds are picked up without a list.
local portalCache
function ns.KnownPortals()
    if portalCache then return portalCache end
    local list, seen = {}, {}
    local function Add(id)
        if not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    for _, id in ipairs(ns.PORTALS) do
        if Known(id) then Add(id) end
    end
    local sample = ns.SpellName(ns.PORTALS[1])
    local prefix = sample and sample:match("^(.-)%s*:")
    if prefix and prefix ~= "" then
        pcall(ScanSpellbook, function(id, name)
            if type(name) == "string" and name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match("^%s*:") then Add(id) end
        end)
    end
    -- Test mode on a character without portals: the faction's classic three.
    if ns.testMode and #list == 0 then
        for _, id in ipairs(FACTION_PORTALS[UnitFactionGroup("player")] or FACTION_PORTALS.Alliance) do
            if ns.SpellName(id) then Add(id) end
        end
    end
    table.sort(list)
    portalCache = list
    return list
end

function ns.OfferedPortals()
    local list = {}
    for _, id in ipairs(ns.KnownPortals()) do
        if not ns.char.portalsOff[id] then list[#list + 1] = id end
    end
    return list
end

function ns.Roles()
    if ns.testMode then return { "S", "P", "C" } end
    local _, class = UnitClass("player")
    if class == "WARLOCK" and Known(ns.SUMMON_SPELL) then return { "S", "C" } end
    if class == "MAGE" and #ns.KnownPortals() > 0 then return { "P", "C" } end
    return { "C" }
end

function ns.KindName(kind)
    return kind == "S" and L["Summoning"] or kind == "P" and L["Portals"] or L["Clicker"]
end

-- Maps ---------------------------------------------------------------------

local parents = {}
local function Parent(map)
    local parent = parents[map]
    if parent == nil then
        local info = C_Map.GetMapInfo(map)
        parent = info and info.parentMapID or 0
        parents[map] = parent
    end
    return parent
end
ns.ParentMap = Parent

function ns.MapName(map)
    local info = map and C_Map.GetMapInfo(map)
    return info and info.name or "?"
end

function ns.InMap(map, root)
    for _ = 1, 12 do
        if not map or map == 0 then return false end
        if map == root then return true end
        map = Parent(map)
    end
    return false
end

-- Direct child of root on the way down to map.
function ns.ChildToward(map, root)
    for _ = 1, 12 do
        if not map or map == 0 then return end
        local parent = Parent(map)
        if parent == root then return map end
        map = parent
    end
end

local function Ancestor(map, wanted)
    for _ = 1, 12 do
        if not map or map == 0 then return end
        local info = C_Map.GetMapInfo(map)
        if not info then return end
        if info.mapType == wanted then return map end
        map = info.parentMapID
    end
end

function ns.RootMap()
    local map = C_Map.GetBestMapForUnit("player")
    return Ancestor(map, 1) or (C_Map.GetFallbackWorldMapID and C_Map.GetFallbackWorldMapID()) or 947
end

function ns.Continent(map)
    return Ancestor(map, 2)
end

-- Continents, then the world map.
function ns.Continents()
    local root = ns.RootMap()
    local list = {}
    for _, info in ipairs(C_Map.GetMapChildrenInfo(root, 2, false) or {}) do list[#list + 1] = info.mapID end
    if #list == 0 then
        for _, info in ipairs(C_Map.GetMapChildrenInfo(root, 2, true) or {}) do list[#list + 1] = info.mapID end
    end
    table.sort(list, function(a, b) return ns.MapName(a) < ns.MapName(b) end)
    list[#list + 1] = root
    return list
end

function ns.HomeMap()
    return Ancestor(C_Map.GetBestMapForUnit("player"), 2) or ns.RootMap()
end

local lastPos
function ns.PlayerPos()
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return end
    lastPos = { map, x, y }
    return map, x, y
end

local function World(map, x, y)
    local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if ok and continent and pos then return continent, pos.x, pos.y end
end

-- Yards between the player and an offer; nil across continents.
function ns.Distance(offer, here)
    if not here then return end
    local c1, x1, y1 = World(here[1], here[2], here[3])
    local c2, x2, y2 = World(offer.map, offer.x, offer.y)
    if not c1 or c1 ~= c2 then return end
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

function ns.Here()
    local map, x, y = ns.PlayerPos()
    return map and { map, x, y } or nil
end

-- Own offer ----------------------------------------------------------------

function ns.ClickersNearby()
    local count = 0
    local raid = IsInRaid()
    for index = 1, raid and 40 or 4 do
        local unit = (raid and "raid" or "party") .. index
        if UnitExists(unit) and not UnitIsUnit(unit, "player") and UnitIsVisible(unit) and not UnitIsDeadOrGhost(unit) then
            count = count + 1
        end
    end
    return math.min(count, 2)
end

-- Why the offer is paused, or nil when it may go out.
function ns.Suspended()
    if ns.db.autoAfk and UnitIsAFK("player") then return "AFK" end
    if ns.db.autoInstance and IsInInstance() then return "INSTANCE" end
    if not ns.PlayerPos() and not lastPos then return "NOPOS" end
    if ns.char.kind == "P" and #ns.OfferedPortals() == 0 then return "NODEST" end
end

function ns.IsLive()
    return ns.char.active and not ns.Suspended()
end

function ns.OwnOffer()
    local char = ns.char
    local map, x, y = ns.PlayerPos()
    if not map then
        if not lastPos then return end
        map, x, y = lastPos[1], lastPos[2], lastPos[3]
    end
    local offer = { name = ns.me, kind = char.kind, map = map, x = x, y = y, fee = char.fee[char.kind] or 0, note = char.note or "", own = true,
        test = ns.testMode or nil }
    if char.kind == "S" then
        offer.ready = ns.ClickersNearby()
        offer.pay = char.clickerPay or 0
    elseif char.kind == "P" then
        offer.dests = ns.OfferedPortals()
    end
    return offer
end

function ns.SetActive(active)
    ns.char.active = active and true or false
    ns.Refresh()
    if ns.testMode then ns.AddTestRequests() end
    ns.Tick()
end

-- The service this class may offer outside test mode.
local function ClassKind(kind)
    local _, class = UnitClass("player")
    local own = class == "WARLOCK" and "S" or class == "MAGE" and "P" or "C"
    if kind == "C" or kind == own then return kind end
    return own, true
end

-- Test mode: any class may act as warlock or mage. Its offers go out marked as tests and only players
-- who are in test mode too see them.
function ns.SetTestMode(on)
    ns.testMode = on and true or false
    portalCache = nil
    if ns.testMode then
        ns.AddTestOffers()
    else
        for name, offer in pairs(ns.offers) do
            if offer.fake or offer.test then ns.offers[name] = nil end
        end
        for _, list in ipairs({ ns.incoming, ns.calls }) do
            for name, entry in pairs(list) do
                if entry.fake then list[name] = nil end
            end
        end
        local kind, changed = ClassKind(ns.char.kind)
        ns.char.kind = kind
        if changed then ns.char.active = false end
    end
    ns.Tick()
    ns.Refresh()
end

-- Made-up requests that fit the own offer, to try Accept and Decline alone.
function ns.AddTestRequests()
    for _, list in ipairs({ ns.incoming, ns.calls }) do
        for name, entry in pairs(list) do
            if entry.fake then list[name] = nil end
        end
    end
    local char = ns.char
    if not char.active then return end
    local now = GetTime()
    local function Add(name, kind, arg)
        ns.incoming[name] = { name = name, kind = kind, arg = arg or 0, time = now + 100000, fake = true }
    end
    if char.kind == "S" then
        Add("Test1", "S")
        Add("Test3", "S")
    elseif char.kind == "P" then
        local dests = ns.OfferedPortals()
        if dests[1] then Add("Test1", "P", dests[1]) end
        if dests[2] then Add("Test3", "P", dests[2]) end
    else
        local map, x, y = ns.PlayerPos()
        if map then ns.calls.Test1 = { name = "Test1", pay = 5000, map = map, x = x, y = y, dist = 40, time = now + 100000, fake = true } end
    end
    ns.Alert()
end

-- Lists --------------------------------------------------------------------

local function Matches(offer, filter)
    if filter.maxFee and filter.maxFee > 0 and offer.fee > filter.maxFee then return false end
    if offer.kind == "S" and filter.readyOnly and (offer.ready or 0) < 2 then return false end
    if offer.kind == "P" and filter.dest and filter.dest ~= 0 then
        local found = false
        for _, id in ipairs(offer.dests or {}) do found = found or id == filter.dest end
        if not found then return false end
    end
    local text = filter.text
    if text and text ~= "" then
        text = text:lower()
        local hay = (offer.name .. " " .. (offer.zone or "") .. " " .. (offer.note or "")):lower()
        if not hay:find(text, 1, true) then return false end
    end
    return true
end

local function SortValue(offer, key)
    if key == "status" then
        if offer.kind == "P" then return -#(offer.dests or {}) end
        return -(offer.ready or 0)
    end
    return offer[key]
end

-- Offers of one kind, filtered and sorted. map limits to that map and its children.
function ns.List(kind, map, filter, key, down)
    filter = filter or {}
    key = key or "fee"
    local here = ns.Here()
    local out = {}
    for _, offer in pairs(ns.offers) do
        if offer.kind == kind and (not map or ns.InMap(offer.map, map)) then
            offer.zone = ns.MapName(offer.map)
            offer.dist = ns.Distance(offer, here)
            if Matches(offer, filter) then out[#out + 1] = offer end
        end
    end
    table.sort(out, function(a, b)
        local x, y = SortValue(a, key), SortValue(b, key)
        if x == nil or y == nil then
            if x ~= y then return y == nil end
        elseif x ~= y then
            if down then return x > y end
            return x < y
        end
        return a.name < b.name
    end)
    return out
end

-- The world map tab is open: offers are wanted.
function ns.Browsing()
    return ns.WorldMapActive ~= nil and ns.WorldMapActive()
end

local refreshing = false
function ns.Refresh()
    ns.version = (ns.version or 0) + 1
    if refreshing or not ns.UpdateWindow then return end
    refreshing = true
    C_Timer.After(0.1, function()
        refreshing = false
        ns.UpdateWindow()
        if ns.UpdateRequests then ns.UpdateRequests() end
        if ns.UpdateOrb then ns.UpdateOrb() end
    end)
end

-- Test data ----------------------------------------------------------------

function ns.AddTestOffers()
    local zones = C_Map.GetMapChildrenInfo(ns.HomeMap(), 3, false) or {}
    if #zones == 0 then return ns.Print("No zones.") end
    local now = GetTime()
    for index = 1, 60 do
        local zone = zones[math.random(math.min(#zones, 6))]
        local kind = index % 2 == 0 and "P" or "S"
        local offer = { name = "Test" .. index, kind = kind, map = zone.mapID, x = 0.2 + math.random() * 0.6, y = 0.2 + math.random() * 0.6,
            fee = math.random(0, 40) * 2500, note = index % 3 == 0 and "Test offer" or "", seen = now, ttl = 1e9, fake = true }
        if kind == "S" then
            offer.ready, offer.pay = math.random(0, 2), 5000
        elseif kind == "P" then
            offer.dests = {}
            -- Only the own faction's cities.
            local cities = FACTION_PORTALS[UnitFactionGroup("player")] or FACTION_PORTALS.Alliance
            for _, id in ipairs(cities) do
                if math.random() < 0.5 then offer.dests[#offer.dests + 1] = id end
            end
            if #offer.dests == 0 then offer.dests[1] = cities[1] end
        end
        ns.offers[offer.name] = offer
    end
    ns.Refresh()
end

-- Events -------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        WormholeDB = ns.ApplyDefaults(WormholeDB or {}, ns.defaults)
        WormholeCharDB = ns.ApplyDefaults(WormholeCharDB or {}, ns.charDefaults)
        ns.db, ns.char = WormholeDB, WormholeCharDB
    elseif event == "PLAYER_LOGIN" then
        ns.me = UnitName("player")
        -- A service picked in test mode does not survive a login.
        local kind, changed = ClassKind(ns.char.kind or "")
        ns.char.kind = kind
        if changed then ns.char.active = false end
        if ns.db.view ~= "S" and ns.db.view ~= "P" then ns.db.view = "S" end
        ns.StartNet()
        if ns.InitOptions then pcall(ns.InitOptions) end
        if ns.InitWorldMap then
            local ok, err = pcall(ns.InitWorldMap)
            if not ok then ns.Print(tostring(err)) end
        end
        ns.UpdateMinimapButton()
        ns.UpdateOrb()
        for _, name in ipairs({ "PLAYER_FLAGS_CHANGED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "SPELLS_CHANGED" }) do
            self:RegisterEvent(name)
        end
        ns.grouped = IsInGroup()
        if ns.char.active then ns.Print(L["Offer Active"]) end
    elseif event == "PLAYER_FLAGS_CHANGED" then
        if arg1 == "player" then ns.Tick() end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Joined someone's group: the open requests to everyone else are withdrawn.
        local grouped = IsInGroup()
        if grouped and not ns.grouped and not UnitIsGroupLeader("player") then ns.RetractAll() end
        ns.grouped = grouped
        ns.Tick()
    elseif event == "SPELLS_CHANGED" then
        portalCache = nil
    else
        ns.Tick()
    end
end)

SLASH_WORMHOLE1 = "/wormhole"
SLASH_WORMHOLE2 = "/wh"
SlashCmdList.WORMHOLE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "test" then
        ns.SetTestMode(not ns.testMode)
        ns.Print(("%s: %s"):format(L["Test Mode"], ns.testMode and L["Active"] or L["Inactive"]))
        if ns.testMode then
            ns.Print(L["Act as any service. Only other testers see your offer."])
            ns.ToggleWindow(true)
        end
    elseif msg == "on" or msg == "off" then
        ns.SetActive(msg == "on")
        ns.Print(ns.char.active and L["Offer Active"] or L["Offer Inactive"])
    elseif msg == "requests" or msg == "jobs" then
        ns.ShowRequests()
    elseif msg == "options" then
        if ns.OpenOptions then ns.OpenOptions() end
    else
        ns.ToggleWindow()
    end
end
