-- Run from the addon folder: luajit tests/spec.lua
-- Loads the addon once per simulated player with a stubbed game API and a tiny message router.

local clock = 0
local clients, channel = {}, {}
local MAPS = {
    [947] = { name = "Azeroth", mapType = 1, parentMapID = 946 },
    [1414] = { name = "Kalimdor", mapType = 2, parentMapID = 947 },
    [1413] = { name = "The Barrens", mapType = 3, parentMapID = 1414 },
    [1411] = { name = "Durotar", mapType = 3, parentMapID = 1414 },
}

local METHOD = { "^Set", "^Get", "^Is", "^Create", "^Register", "^Hook", "^Enable", "^Clear", "^Show$", "^Hide$", "^Start", "^Stop", "^Has", "^Refresh$", "^Add", "^Click$" }
local function Widget()
    local self = { shown = true, scripts = {}, _text = "" }
    local numbers = { GetWidth = 480, GetHeight = 320, GetStringWidth = 10, GetEffectiveScale = 1, GetLeft = 0, GetTop = 0, GetFrameLevel = 1, GetID = 1 }
    return setmetatable(self, { __index = function(_, key)
        if key == "Show" then return function() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
        if key == "Hide" then return function() self.shown = false end end
        if key == "SetShown" then return function(_, on) if on then self:Show() else self:Hide() end end end
        if key == "IsShown" then return function() return self.shown end end
        if key == "SetCustomOnMouseUpHandler" then return function(_, fn) self.scripts.OnMouseUp = function(frame, button) fn(frame, button, true) end end end
        if key == "SetScript" then return function(_, name, fn) self.scripts[name] = fn end end
        if key == "SetText" then return function(_, text) self._text = tostring(text) end end
        if key == "GetText" then return function() return self._text end end
        if key == "HasFocus" or key == "IsMouseOver" or key == "GetChecked" then return function() return false end end
        if numbers[key] then return function() return numbers[key] end end
        for _, pattern in ipairs(METHOD) do
            if key:find(pattern) then return function() return Widget() end end
        end
    end })
end

local withMap = false
local function NewClient(name, class, spells)
    local c = { name = name, afk = false, instance = false, pos = { 1413, 0.5, 0.5 }, group = {}, invited = {}, timers = {}, printed = {}, events = {} }
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.GetLocale = function() return "enUS" end
    env.GetTime = function() return clock end
    env.print = function(msg) c.printed[#c.printed + 1] = msg end
    env.strsplit = function(sep, text)
        local out = {}
        for part in (text .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
        return unpack(out)
    end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end end
    env.tinsert = table.insert
    env.UnitName = function() return name end
    env.UnitClass = function() return class, class end
    env.UnitFactionGroup = function() return "Horde" end
    env.UnitIsAFK = function() return c.afk end
    env.IsInInstance = function() return c.instance end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return #c.group > 0 end
    env.GetNumGroupMembers = function() return #c.group end
    env.UnitIsGroupLeader = function() return not c.follower end
    env.UnitInRaid = function() return false end
    env.UnitInParty = function(who)
        for _, member in ipairs(c.group) do
            if member == who then return true end
        end
        return false
    end
    env.UnitExists = function(unit) return c.group[tonumber(unit:match("%d+"))] ~= nil end
    env.UnitIsUnit = function() return false end
    env.UnitIsVisible = function() return true end
    env.UnitIsDeadOrGhost = function() return false end
    env.IsPlayerSpell = function(id) return spells[id] or false end
    env.GetSpellInfo = function(id) return "Portal: City" .. id end
    env.GetSpellTexture = function() return 1 end
    env.GetMoneyString = function(copper) return copper .. "c" end
    env.Ambiguate = function(sender) return sender end
    env.InviteUnit = function(who) c.invited[#c.invited + 1] = who end
    env.CreateVector2D = function(x, y) return { x = x, y = y } end
    env.GameTooltip = Widget()
    env.UIParent, env.Minimap, env.UISpecialFrames = Widget(), Widget(), {}
    env.SlashCmdList = {}
    env.hooksecurefunc = function() end
    if withMap then
        local map, quest = Widget(), Widget()
        c.mapID = 1414
        rawset(map, "GetMapID", function() return c.mapID end)
        rawset(map, "GetCanvasScale", function() return 0.5 end)
        rawset(map, "shown", false)
        rawset(quest, "ContentFrames", { Widget() })
        env.WorldMapFrame, env.QuestMapFrame = map, quest
        c.map = map
    end
    env.CreateFrame = function()
        local frame = Widget()
        rawset(frame, "RegisterEvent", function() end)
        c.frames = c.frames or {}
        c.frames[#c.frames + 1] = frame
        return frame
    end
    env.C_Map = {
        GetMapInfo = function(id) local m = MAPS[id]; return m and { name = m.name, mapType = m.mapType, parentMapID = m.parentMapID, mapID = id } end,
        GetBestMapForUnit = function() return c.pos and c.pos[1] or nil end,
        GetPlayerMapPosition = function() return c.pos and { GetXY = function() return c.pos[2], c.pos[3] end } end,
        GetWorldPosFromMapPos = function(map, v) return 1, { x = v.x * 1000 + map, y = v.y * 1000 } end,
        GetMapChildrenInfo = function() return { { mapID = 1413 }, { mapID = 1411 } } end,
        GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
        GetMapArtLayerTextures = function() return { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } end,
        GetMapRectOnMap = function() return 0.2, 0.4, 0.2, 0.4 end,
        GetMapInfoAtPosition = function() end,
    }
    env.GetChannelName = function() return channel[name] and 5 or 0 end
    env.JoinChannelByName = function() channel[name] = true end
    env.LeaveChannelByName = function() channel[name] = nil end
    env.C_Timer = { After = function(delay, fn) c.timers[#c.timers + 1] = { clock + delay, fn } end,
        NewTicker = function(period, fn) if period < 1 then c.watch = fn end end }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, msg, dist, target)
            assert(#msg <= 255, "message too long")
            c.sent = (c.sent or 0) + 1
            for _, other in pairs(clients) do
                local hears = (dist == "CHANNEL" and channel[name] and channel[other.name]) or (dist == "WHISPER" and (other.sendAs or other.name) == target)
                if hears then other.onAddon(prefix, msg, dist, c.sendAs or name) end
            end
            return 0
        end,
    }
    local ns = {}
    for _, file in ipairs({ "Locales.lua", "Core.lua", "Net.lua", "UI.lua", "Requests.lua", "WorldMap.lua", "Minimap.lua" }) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, env)
        chunk("Wayfarer", ns)
    end
    c.ns, c.env = ns, env
    -- Stands in for the world map tab being open.
    if not env.WorldMapFrame then ns.WorldMapActive = function() return c.browsing or false end end
    -- Core's frame is the first one created; Net's is created by StartNet.
    local core = c.frames[1]
    core.scripts.OnEvent(core, "ADDON_LOADED", "Wayfarer")
    core.scripts.OnEvent(core, "PLAYER_LOGIN")
    local net
    for _, frame in ipairs(c.frames) do
        if frame.scripts.OnEvent and frame ~= core and not net then net = frame end
    end
    c.onAddon = function(prefix, msg, dist, sender) net.scripts.OnEvent(net, "CHAT_MSG_ADDON", prefix, msg, dist, sender) end
    clients[name] = c
    return c
end

local function Advance(seconds)
    for _ = 1, seconds do
        clock = clock + 1
        for _, c in pairs(clients) do
            local due = {}
            for index = #c.timers, 1, -1 do
                if c.timers[index][1] <= clock then due[#due + 1] = table.remove(c.timers, index)[2] end
            end
            for _, fn in ipairs(due) do fn() end
            if c.watch then c.watch() end
            c.ns.Tick()
        end
    end
end

local function Browse(c)
    c.browsing = not c.browsing
    c.ns.Tick()
    if c.browsing and c.ns.net.joined then c.ns.Query() end
end

local passed = 0
local function Check(cond, what)
    if not cond then error("FAILED: " .. what, 2) end
    passed = passed + 1
end

local lock = NewClient("Lock", "WARLOCK", { [698] = true })
local mage = NewClient("Mage", "MAGE", { [10059] = true, [11416] = true })
local buyer = NewClient("Buyer", "ROGUE", {})
local click = NewClient("Click", "WARRIOR", {})
Advance(15)

-- Roles
Check(lock.ns.char.kind == "S" and mage.ns.char.kind == "P" and buyer.ns.char.kind == "C", "role by class")
Check(#mage.ns.KnownPortals() == 2, "known portals")

-- Nobody browsing or offering: nobody in the channel.
Check(next(channel) == nil, "channel stays empty while idle")

-- Offers reach a browsing player.
buyer.ns.ToggleWindow(true)
Check(buyer.ns.WindowShown(), "setup window opens: " .. tostring(buyer.printed[#buyer.printed]))
Browse(buyer)
lock.ns.char.fee.S, lock.ns.char.note = 50000, "Stone at the gate|cff"
lock.ns.SetActive(true)
mage.ns.char.fee.P = 20000
mage.pos = { 1411, 0.3, 0.7 }
mage.ns.SetActive(true)
Advance(10)
local seen = buyer.ns.offers.Lock
Check(seen and seen.kind == "S" and seen.fee == 50000 and seen.map == 1413 and seen.ready == 0, "summon offer received")
Check(seen.note == "Stone at the gate cff", "note is stripped of escapes")
Check(buyer.ns.offers.Mage and #buyer.ns.offers.Mage.dests == 2, "portal offer received")

-- Lists: filter, sort, map scope.
local list = buyer.ns.List("S", nil, {})
Check(#list == 1 and list[1].zone == "The Barrens" and list[1].dist == 0, "summon list with zone and distance")
Check(#buyer.ns.List("S", nil, { readyOnly = true }) == 0, "ready filter")
Check(#buyer.ns.List("S", nil, { maxFee = 40000 }) == 0 and #buyer.ns.List("S", nil, { maxFee = 50000 }) == 1, "fee filter")
Check(#buyer.ns.List("P", nil, { dest = 11416 }) == 1 and #buyer.ns.List("P", nil, { dest = 11417 }) == 0, "destination filter")
Check(#buyer.ns.List("P", 1413, {}) == 0 and #buyer.ns.List("P", 1411, {}) == 1 and #buyer.ns.List("P", 1414, {}) == 1, "map scope")
Check(#buyer.ns.List("S", nil, { text = "gate" }) == 1 and #buyer.ns.List("S", nil, { text = "nope" }) == 0, "text filter")
buyer.ns.offers.Zed = { name = "Zed", kind = "S", map = 1411, x = 0.1, y = 0.1, fee = 100, ready = 2, seen = clock, ttl = 500 }
list = buyer.ns.List("S", nil, {}, "fee", false)
Check(list[1].name == "Zed" and list[2].name == "Lock", "sort by fee")
list = buyer.ns.List("S", nil, {}, "name", false)
Check(list[1].name == "Lock", "sort by name")
list = buyer.ns.List("S", nil, {}, "status", false)
Check(list[1].name == "Zed", "sort by clickers ready")
Check(buyer.ns.ChildToward(1413, 1414) == 1413 and buyer.ns.ChildToward(1413, 947) == 1414, "zone counts roll up")

-- The window renders both views without errors.
buyer.ns.Select("Lock")
buyer.ns.db.view = "P"
buyer.ns.Select("Mage")
buyer.ns.ToggleWindow(true)
lock.ns.ToggleWindow(true)
mage.ns.ToggleWindow(true)
Browse(lock)
for _, offer in pairs(buyer.ns.offers) do buyer.ns.OfferTooltip(buyer.env.UIParent, offer) end
late_test = NewClient("Tester", "HUNTER", {})
late_test.ns.AddTestOffers()
Browse(late_test)
Advance(1)
Check(#late_test.ns.List("S", nil, {}) > 0 and #late_test.ns.List("P", 1414, {}) > 0, "test offers")
for _, offer in pairs(late_test.ns.offers) do
    for _, id in ipairs(offer.dests or {}) do Check(id == 11417 or id == 11418 or id == 11420, "test portals stay in the faction") end
end
clients.Tester = nil

-- Summon request, accepted: the warlock invites.
buyer.ns.Request("Lock", "S")
Check(lock.ns.incoming.Buyer and lock.ns.incoming.Buyer.kind == "S", "request arrives")
lock.ns.Answer("Buyer", true)
Check(lock.invited[1] == "Buyer", "warlock invites the customer")
Check(buyer.ns.outgoing.Lock.state == "ACCEPTED", "customer sees the accept")

-- Portal request for a destination the mage does not offer is declined.
mage.ns.char.portalsOff[11416] = true
Advance(8)
Check(#buyer.ns.offers.Mage.dests == 1, "edited offer is rebroadcast")
buyer.ns.Request("Mage", "P", 11416)
Check(mage.ns.incoming.Buyer == nil and buyer.ns.outgoing.Mage.state == "DECLINED", "unoffered portal declined")

-- Clicker calls: the warlock asks, clickers in range are told, the first two to accept are invited.
local far = NewClient("Far", "PRIEST", {})
local third = NewClient("Third", "PRIEST", {})
Advance(13)
for _, c in ipairs({ click, far, third }) do c.ns.SetActive(true) end
far.pos = { 1413, 0.95, 0.5 }
lock.ns.char.clickerPay = 5000
Advance(8)
Check(lock.ns.offers.Click == nil and buyer.ns.offers.Click == nil, "clickers broadcast no offer")
Check(channel.Click == true, "an active clicker listens on the channel")
lock.ns.CallClickers()
Check(lock.ns.call and lock.ns.call.need == 2, "call opens for the missing clickers")
Check(click.ns.calls.Lock and click.ns.calls.Lock.pay == 5000 and click.ns.calls.Lock.dist == 0, "clicker in range hears the call")
Check(far.ns.calls.Lock == nil, "clicker out of range is not bothered")
Check(buyer.ns.calls.Lock == nil, "players who are not clickers are not bothered")
far.ns.char.range = 0
lock.ns.EndCall()
Check(click.ns.calls.Lock == nil, "ended call disappears")
lock.ns.CallClickers()
Check(far.ns.calls.Lock ~= nil, "same zone range hears it")
click.ns.Apply("Lock")
Check(lock.invited[#lock.invited] == "Click" and next(click.ns.calls) == nil, "accepting clicker is invited")
Check(lock.ns.call and lock.ns.call.count == 1, "call stays open for the second clicker")
far.ns.Apply("Lock")
Check(lock.invited[#lock.invited] == "Far" and lock.ns.call == nil, "second clicker fills the call")
Check(third.ns.calls.Lock == nil, "filled call disappears for the others")
third.ns.calls.Lock = { name = "Lock", pay = 5000, map = 1413, x = 0.5, y = 0.5, time = clock }
local invites = #lock.invited
third.ns.Apply("Lock")
Check(#lock.invited == invites and third.ns.calls.Lock == nil, "a late clicker is turned down")
lock.ns.ShowRequests()
click.ns.ShowRequests()
lock.ns.CallClickers()
Advance(65)
Check(lock.ns.call == nil and third.ns.calls.Lock == nil, "unanswered call runs out")
for _, c in ipairs({ far, third }) do c.ns.SetActive(false) end
clients.Far, clients.Third, channel.Far, channel.Third = nil, nil, nil, nil

-- Switching the service off declines everything that waits.
buyer.ns.outgoing = {}
buyer.ns.Request("Lock", "S")
Check(lock.ns.incoming.Buyer ~= nil, "request waits")
lock.ns.SetActive(false)
Check(lock.ns.incoming.Buyer == nil and buyer.ns.outgoing.Lock.state == "DECLINED", "deactivating declines all requests")
lock.ns.SetActive(true)
buyer.ns.outgoing = {}
Advance(8)

-- Clickers in the group show as ready.
lock.group = { "Click", "Buyer" }
Advance(8)
Check(buyer.ns.offers.Lock.ready == 2, "clickers nearby are broadcast")

-- AFK pauses and withdraws; coming back restores.
lock.afk = true
Advance(3)
Check(not lock.ns.IsLive() and buyer.ns.offers.Lock == nil, "afk withdraws the offer")
lock.ns.db.autoAfk = false
Advance(8)
Check(buyer.ns.offers.Lock ~= nil, "afk pause can be switched off")
lock.instance, lock.pos = true, nil
Advance(3)
Check(buyer.ns.offers.Lock == nil, "instance withdraws the offer")
lock.instance, lock.pos = false, { 1413, 0.5, 0.5 }
Advance(8)
Check(buyer.ns.offers.Lock ~= nil, "offer returns after the instance")

-- A new browser asks and gets answers before the next beat.
Advance(30)
local late = NewClient("Late", "PRIEST", {})
Advance(13)
Browse(late)
Advance(12)
Check(late.ns.offers.Lock and late.ns.offers.Mage, "query is answered")

-- Offers expire when the sender goes silent.
clients.Mage = nil
channel.Mage = nil
Advance(200)
Check(buyer.ns.offers.Mage == nil and buyer.ns.offers.Lock ~= nil, "silent offers expire")

-- Steady state stays quiet: one broadcast a minute per offer.
lock.sent = 0
Advance(120)
-- Each beat is one channel message and one yell.
Check(lock.sent <= 4, "heartbeat rate, sent " .. lock.sent)

-- Leaving: window closed and inactive leaves the channel.
Browse(buyer)
Advance(70)
Check(channel.Buyer == nil and channel.Lock == true, "idle client leaves the channel")

-- Test mode: a rogue acts as warlock and mage; only testers see the offer.
Browse(buyer)
click.ns.SetTestMode(true)
Check(#click.ns.Roles() == 3, "test mode opens every service")
click.ns.SetActive(true)
Check(click.ns.calls.Test1 and click.ns.calls.Test1.fake, "made-up clicker job")
click.ns.Apply("Test1")
Check(click.ns.calls.Test1 == nil, "made-up job can be accepted")
click.ns.char.kind = "S"
click.ns.SetActive(true)
Advance(8)
Check(click.ns.offers.Click.kind == "S" and click.ns.offers.Click.test, "tester offers summons")
Check(buyer.ns.offers.Click == nil, "players outside test mode do not see test offers")
Check(click.ns.incoming.Test1 and click.ns.incoming.Test3, "made-up requests appear")
click.ns.Answer("Test1", true)
Check(#click.invited == 0 and click.ns.incoming.Test1 == nil, "made-up request invites nobody")
buyer.ns.SetTestMode(true)
Advance(70)
Check(buyer.ns.offers.Click and buyer.ns.offers.Click.kind == "S", "another tester sees the test offer")
buyer.ns.Request("Click", "S")
Check(click.ns.incoming.Buyer ~= nil, "testers can request each other")
click.ns.char.kind = "P"
click.ns.SetActive(true)
Advance(8)
Check(#click.ns.offers.Click.dests == 3 and click.ns.offers.Click.dests[1] == 11417, "tester offers the faction's portals")
Check(click.ns.incoming.Test1.kind == "P", "made-up portal request")
click.ns.ToggleWindow(true)
click.ns.SetTestMode(false)
Check(click.ns.char.kind == "C" and not click.ns.char.active and click.ns.offers.Test1 == nil and click.ns.incoming.Test1 == nil, "leaving test mode cleans up")
buyer.ns.SetTestMode(false)
Browse(buyer)
Advance(3)

-- At most three open requests; an invite withdraws the others.
for index = 1, 4 do
    local name = "W" .. index
    local w = NewClient(name, "WARLOCK", { [698] = true })
    Advance(13)
    w.ns.SetActive(true)
end
Browse(buyer)
Advance(70)
buyer.ns.outgoing = {}
for index = 1, 4 do buyer.ns.Request("W" .. index, "S") end
Check(buyer.ns.OpenRequests() == 3 and clients.W4.ns.incoming.Buyer == nil and clients.W3.ns.incoming.Buyer, "three requests at once")
buyer.ns.Cancel("W3")
Check(clients.W3.ns.incoming.Buyer == nil and buyer.ns.OpenRequests() == 2, "cancel withdraws the request")
buyer.ns.Request("W4", "S")
Check(clients.W4.ns.incoming.Buyer ~= nil, "a freed slot can be used")
buyer.ns.UpdateWindow()
local core = buyer.frames[1]
core.scripts.OnEvent(core, "GROUP_ROSTER_UPDATE")
Check(buyer.ns.OpenRequests() == 3, "no group, nothing withdrawn")
buyer.group, buyer.follower = { "W1" }, true
core.scripts.OnEvent(core, "GROUP_ROSTER_UPDATE")
Check(buyer.ns.outgoing.W1 and buyer.ns.OpenRequests() == 1, "joining keeps the request to the group")
Check(clients.W2.ns.incoming.Buyer == nil and clients.W4.ns.incoming.Buyer == nil and clients.W1.ns.incoming.Buyer, "joining withdraws the other requests")
buyer.group, buyer.follower = {}, false
core.scripts.OnEvent(core, "GROUP_ROSTER_UPDATE")
local list = buyer.ns.Continents()
Check(list[#list] == 947 and buyer.ns.Continent(1413) == 1414, "continents then world")
Advance(30)
buyer.ns.Request("W2", "S")
Advance(40)
Check(buyer.ns.outgoing.W1 == nil and clients.W1.ns.incoming.Buyer == nil, "unanswered request is withdrawn after a minute")
Check(buyer.ns.outgoing.W2 and clients.W2.ns.incoming.Buyer, "younger request still stands")
Advance(25)
Check(buyer.ns.outgoing.W2 == nil and clients.W2.ns.incoming.Buyer == nil, "and is withdrawn in turn")
Browse(buyer)

-- A surname in the sender name does not double the own offer.
local sur = NewClient("Sur", "WARLOCK", { [698] = true })
sur.sendAs = "Sur Name"
Advance(13)
sur.ns.SetActive(true)
Advance(70)
Check(sur.ns.offers.Sur and sur.ns.offers["Sur Name"] == nil and sur.ns.char.alias == "Sur Name", "own echo under a longer name is ignored")
Check(#sur.ns.List("S", 1413, { text = "Sur" }) == 1, "listed once")
Browse(buyer)
Advance(70)
Check(buyer.ns.offers["Sur Name"] ~= nil, "others see the full name")
buyer.ns.outgoing = {}
buyer.ns.Request("Sur Name", "S")
Check(sur.ns.incoming.Buyer ~= nil, "and can request under it")
Browse(buyer)

-- Group checks and automatic invites.
local auto = NewClient("Auto", "WARLOCK", { [698] = true })
local guest = NewClient("Guest", "ROGUE", {})
Advance(13)
auto.ns.SetActive(true)
Browse(guest)
Advance(70)
guest.group, guest.follower = { "Other" }, true
guest.ns.Request("Auto", "S")
Check(guest.ns.outgoing.Auto == nil and auto.ns.incoming.Guest == nil, "grouped player cannot request")
guest.group, guest.follower = {}, false
auto.group, auto.follower = { "Boss" }, true
guest.ns.Request("Auto", "S")
auto.ns.Answer("Guest", true)
Check(auto.ns.incoming.Guest ~= nil and #auto.invited == 0, "no invite without invite rights")
auto.ns.char.autoInvite = true
guest.ns.Cancel("Auto")
guest.ns.outgoing = {}
guest.ns.Request("Auto", "S")
Check(auto.ns.incoming.Guest ~= nil and #auto.invited == 0, "auto invite waits without invite rights")
auto.group, auto.follower = {}, false
guest.ns.Cancel("Auto")
guest.ns.outgoing = {}
guest.ns.Request("Auto", "S")
Check(auto.invited[1] == "Guest" and auto.ns.incoming.Guest == nil and guest.ns.outgoing.Auto.state == "ACCEPTED", "auto invite accepts at once")
Check(not auto.ns.RequestsShown(), "request window stays closed by default")
-- Clickers picked by hand.
auto.ns.char.autoClickers = false
guest.ns.char.kind = "C"
guest.ns.SetActive(true)
auto.ns.CallClickers()
guest.ns.Apply("Auto")
Check(#auto.invited == 1 and auto.ns.incoming.Guest and auto.ns.incoming.Guest.kind == "A", "clicker waits for the warlock")
auto.ns.db.autoOpen = true
auto.ns.ShowRequests()
auto.ns.Answer("Guest", true)
Check(auto.invited[2] == "Guest" and auto.ns.call.count == 1 and next(guest.ns.calls) == nil, "picked clicker is invited")
guest.ns.ShowRequests()
clients.Auto, clients.Guest, channel.Auto, channel.Guest = nil, nil, nil, nil

-- World map tab: selecting it starts browsing, lists the shown map's offers and requests from there.
withMap = true
local mapper = NewClient("Mapper", "ROGUE", {})
withMap = false
Advance(15)
Check(not mapper.ns.WorldMapActive() and channel.Mapper == nil, "world map tab idle until selected")
mapper.map.shown = true
local tabFrame
for _, frame in ipairs(mapper.frames) do
    if rawget(frame, "tooltipText") == "Wayfarer" then tabFrame = frame end
end
Check(tabFrame ~= nil, "side tab is created")
tabFrame.scripts.OnMouseUp(tabFrame, "LeftButton")
Advance(75)
Check(mapper.ns.WorldMapActive() and channel.Mapper == true, "selected tab joins the channel")
Check(mapper.ns.offers.Lock ~= nil and mapper.ns.mapError == nil, "offers arrive and the map draws: " .. tostring(mapper.printed[#mapper.printed]))
mapper.mapID = 1413
mapper.ns.selected = "Lock"
Advance(2)
mapper.ns.db.view = "P"
mapper.ns.offers.Pt = { name = "Pt", kind = "P", map = 1413, x = 0.4, y = 0.4, fee = 100, dests = { 11417, 11418 }, seen = clock, ttl = 500 }
mapper.ns.selected = "Pt"
mapper.ns.Refresh()
Advance(2)
Check(mapper.ns.mapError == nil, "zone map draws: " .. tostring(mapper.printed[#mapper.printed]))
-- A press and release over a pin selects its offer.
local pinFrame, mouseFrame
for _, frame in ipairs(mapper.frames) do
    if rawget(frame, "offer") and rawget(frame, "offer").name == "Lock" then pinFrame = frame end
    if frame.scripts.OnEvent and frame ~= mapper.frames[1] then mouseFrame = frame end
end
mapper.ns.db.view = "S"
mapper.ns.selected = nil
mapper.ns.Refresh()
Advance(2)
for _, frame in ipairs(mapper.frames) do
    if rawget(frame, "offer") and rawget(frame, "offer").name == "Lock" and frame.scripts.OnEnter then pinFrame = frame end
end
Check(pinFrame ~= nil, "pin exists for the offer")
rawset(pinFrame, "IsMouseOver", function() return true end)
pinFrame.scripts.OnEnter(pinFrame)
mouseFrame.scripts.OnEvent(mouseFrame, "GLOBAL_MOUSE_DOWN", "LeftButton")
mouseFrame.scripts.OnEvent(mouseFrame, "GLOBAL_MOUSE_UP", "LeftButton")
Check(mapper.ns.selected == "Lock", "clicking a pin selects the offer")
tabFrame.scripts.OnMouseUp(tabFrame, "LeftButton")
Advance(2)
Check(not mapper.ns.WorldMapActive(), "tab toggles back to the quest log")
clients.Mapper, channel.Mapper = nil, nil

-- Codec rejects junk.
local ns = buyer.ns
Check(ns.Decode("O\tS\t60\tabc\t1\t1\t0\t0\t0\t0\t") == nil, "bad map")
Check(ns.Decode("O\tZ\t60\t1\t1\t1\t0\t0\t0\t0\t") == nil, "bad kind")
Check(ns.Decode("O\tS\t60\t1\t20000\t1\t0\t0\t0\t0\t") == nil, "bad position")
Check(ns.Decode("O\tP\t60\t1\t1\t1\t0\t\t0\t0\t") == nil, "portal offer without portals")
local back = ns.Decode(ns.Encode({ kind = "P", map = 1411, x = 0.1234, y = 0.9, fee = 12345, dests = { 3, 4 }, note = "a\tb" }, 150))
Check(back.map == 1411 and back.x == 0.1234 and back.fee == 12345 and back.dests[2] == 4 and back.note == "a b" and back.ttl == 150, "codec round trip")

print(("%d checks passed"):format(passed))
