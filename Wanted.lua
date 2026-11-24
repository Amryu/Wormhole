local _, ns = ...
local L = ns.L

-- Wanted: a summon to a spot nobody offers yet. A player marks the spot on the map and posts it. An account
-- with a warlock hears of it when the spot is near one of its warlocks, logged in or not, or at a place it
-- watches. Whoever takes it may be on another character: the accepted request is saved and waits for the
-- warlock to log in.
--
-- Messages, fields split by tabs:
--   W ttl map x y pay area test side   wanted (broadcast). area = the game's area ID at the spot, 0 unknown.
--                                      side = A or H; the other side's requests are dropped.
--   V                             wanted withdrawn or taken (broadcast)
--   H                             who wants a summon? (broadcast)
--   T warlock                     I take it (whisper); warlock = the character that will summon
--   Y W / N W                     the poster agrees / the request is gone or taken (whisper)
--   C                             the poster withdrew after agreeing (whisper)

local WANT_BEAT = 60
local WANT_ANSWER = 20      -- a query is answered only when the last broadcast is older
local WANT_TTL = 1800       -- an own request closes itself
local TAKE_WAIT = 30        -- an unanswered take is dropped
local JOB_TTL = 900         -- an accepted request waits this long for its warlock, on the wall clock
local WANTED_MAX = 500
local PLACE_RANGE = 250     -- yards around a watched place
local NAME_RANGE = 200      -- a spot this close to a named place takes its name
local ARRIVED = 80
local PARK_GAP = 30
local ALERT_EVERY = 5       -- wanted alerts are at least this far apart, whoever posts
ns.WATCH_RANGES = { 300, 500, 1000, 2000, 0 }

ns.wanted = {}

local sentAt, answerAt, parkedAt, asked, alertedAt = 0, nil, -1000, false, -1000

local function Side()
    return UnitFactionGroup("player") == "Alliance" and "A" or "H"
end
local Wall = time or os.time

local realm
local function Realm()
    realm = realm or (GetRealmName and GetRealmName()) or ""
    return realm
end

-- Places ---------------------------------------------------------------------

-- World position of anything with map, x and y; kept beside the table so saved ones stay clean.
local spots = setmetatable({}, { __mode = "k" })
local function Spot(entry)
    local spot = spots[entry]
    if not spot then
        local c, x, y = ns.World(entry.map, entry.x, entry.y)
        spot = { c or false, x, y }
        spots[entry] = spot
    end
    return spot[1], spot[2], spot[3]
end

local function Yards(a, b)
    local ac, ax, ay = Spot(a)
    local bc, bx, by = Spot(b)
    if not ac or ac ~= bc then return end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- Named places of a map: its landmarks and the own faction's flight points, by the game's own data.
local placeCache = {}
function ns.Places(map)
    local list = placeCache[map]
    if list then return list end
    list = {}
    local function Add(key, name, pos)
        if type(name) ~= "string" or name == "" or not pos then return end
        local x, y = pos.x, pos.y
        if not x and pos.GetXY then x, y = pos:GetXY() end
        if not x or not y or x <= 0 or x >= 1 or y <= 0 or y >= 1 then return end
        for _, place in ipairs(list) do
            -- A flight point inside a town already listed.
            if (place.x - x) ^ 2 + (place.y - y) ^ 2 < 0.0009 then return end
        end
        list[#list + 1] = { key = key, name = name, map = map, x = x, y = y }
    end
    pcall(function()
        for _, id in ipairs(C_AreaPoiInfo.GetAreaPOIForMap(map) or {}) do
            local info = C_AreaPoiInfo.GetAreaPOIInfo(map, id)
            if info then Add("P" .. id, info.name, info.position) end
        end
    end)
    pcall(function()
        local mine = UnitFactionGroup("player")
        for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(map) or {}) do
            local other = (node.faction == 1 and mine == "Alliance") or (node.faction == 2 and mine == "Horde")
            if not other then Add("T" .. node.nodeID, tostring(node.name or ""):match("^[^,]+"), node.position) end
        end
    end)
    table.sort(list, function(a, b) return a.name < b.name end)
    placeCache[map] = list
    return list
end

function ns.AreaAt(map, x, y)
    local id
    pcall(function()
        local ids = C_MapExplorationInfo.GetExploredAreaIDsAtPosition(map, CreateVector2D(x, y))
        id = ids and ids[1]
    end)
    return type(id) == "number" and id > 0 and math.floor(id) or 0
end

local function AreaName(id)
    if not id or id == 0 then return end
    local ok, name = pcall(C_Map.GetAreaInfo, id)
    if ok and type(name) == "string" and name ~= "" then return name end
end

-- "Sentinel Hill, Westfall", or "Westfall (56, 47)" where the spot has no name.
local wheres = setmetatable({}, { __mode = "k" })
function ns.Where(entry)
    local text = wheres[entry]
    if text then return text end
    local zone = ns.MapName(entry.map)
    local name = entry.placeName or AreaName(entry.area)
    if not name then
        local best
        for _, place in ipairs(ns.Places(entry.map)) do
            local dist = Yards(entry, place)
            if dist and dist <= NAME_RANGE and (not best or dist < best) then best, name = dist, place.name end
        end
    end
    if name and name ~= zone then
        text = ("%s, %s"):format(name, zone)
    else
        text = ("%s (%d, %d)"):format(zone, entry.x * 100, entry.y * 100)
    end
    wheres[entry] = text
    return text
end

-- Warlocks -------------------------------------------------------------------

function ns.IsWarlock()
    return ns.testMode or ns.Known(ns.SUMMON_SPELL)
end

-- Where this warlock stands, for the account's other characters.
function ns.Park()
    local list = ns.db.warlocks[Realm()]
    if not ns.Known(ns.SUMMON_SPELL) then
        if list then list[ns.me] = nil end
        return
    end
    local map, x, y = ns.PlayerPos()
    if not map then return end
    if not list then
        list = {}
        ns.db.warlocks[Realm()] = list
    end
    local old = list[ns.me]
    list[ns.me] = { map = map, x = x, y = y, faction = UnitFactionGroup("player"), off = old and old.off or nil }
end

-- Every warlock of the account on this realm and side, the one played first.
function ns.AllWarlocks()
    local list = {}
    local saved = ns.db.warlocks[Realm()] or {}
    if ns.IsWarlock() then list[1] = { name = ns.me, here = true, off = saved[ns.me] and saved[ns.me].off or nil } end
    local faction = UnitFactionGroup("player")
    local rest = {}
    for name, spot in pairs(saved) do
        if name ~= ns.me and spot.faction == faction then
            rest[#rest + 1] = { name = name, map = spot.map, x = spot.x, y = spot.y, off = spot.off }
        end
    end
    table.sort(rest, function(a, b) return a.name < b.name end)
    for _, lock in ipairs(rest) do list[#list + 1] = lock end
    return list
end

function ns.WarlockOff(name)
    local list = ns.db.warlocks[Realm()]
    return list ~= nil and list[name] ~= nil and list[name].off == true
end

function ns.SetWarlockOff(name, off)
    local list = ns.db.warlocks[Realm()]
    if not (list and list[name]) then return end
    list[name].off = off and true or nil
    ns.Refresh()
end

-- Alerts are wanted and there is a warlock to summon with.
function ns.Listening()
    return ns.db.watchOn and #ns.AllWarlocks() > 0
end

function ns.WantsChannel()
    return (ns.want ~= nil and ns.want.state == "OPEN") or ns.Listening()
end

local function HereSpot()
    local here = ns.Here()
    return here and { map = here[1], x = here[2], y = here[3] } or nil
end

-- Why a request concerns this account: "NEAR" and the warlock, "ZONE" and the map, "PLACE" and its key.
local function Reason(entry, locks, here)
    local db = ns.db
    for _, lock in ipairs(locks) do
        local spot = lock.here and here or (not lock.here and lock) or nil
        if spot and not lock.off then
            local dist = Yards(entry, spot)
            local near
            if db.watchRange == 0 then near = spot.map == entry.map else near = dist ~= nil and dist <= db.watchRange end
            if near then return "NEAR", lock.name, dist end
        end
    end
    for zone in pairs(db.watchZones) do
        if ns.InMap(entry.map, zone) then return "ZONE", zone end
    end
    for key, place in pairs(db.watchPlaces) do
        local dist = Yards(entry, place)
        if dist and dist <= PLACE_RANGE then return "PLACE", key end
    end
end

function ns.ReasonText(entry)
    if entry.why == "NEAR" then
        local dist = entry.whyDist and ("  %d %s"):format(entry.whyDist, L["yd"]) or ""
        return ("%s: %s%s"):format(L["Near"], entry.what, dist)
    elseif entry.why == "ZONE" then
        return ("%s: %s"):format(L["Watched"], ns.MapName(entry.what))
    elseif entry.why == "PLACE" then
        local place = ns.db.watchPlaces[entry.what]
        return ("%s: %s"):format(L["Watched"], place and ns.Where(place) or "?")
    end
end

local function Mark(entry, locks, here)
    entry.why, entry.what, entry.whyDist = nil, nil, nil
    if entry.own or #locks == 0 or not ns.db.watchOn then return false end
    entry.why, entry.what, entry.whyDist = Reason(entry, locks, here)
    return entry.why ~= nil
end

-- Requests that concern this account and were not put aside.
function ns.Matched()
    local out = {}
    if not ns.Listening() then return out end
    local locks, here = ns.AllWarlocks(), HereSpot()
    for _, entry in pairs(ns.wanted) do
        if not entry.hidden and Mark(entry, locks, here) then out[#out + 1] = entry end
    end
    return out
end

-- Every request, for the map. map limits to that map and its children.
function ns.WantedList(map)
    local out = {}
    local locks, here = ns.AllWarlocks(), HereSpot()
    for _, entry in pairs(ns.wanted) do
        if not map or ns.InMap(entry.map, map) then
            entry.zone = ns.MapName(entry.map)
            entry.dist = here and Yards(entry, here) or nil
            Mark(entry, locks, here)
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a, b)
        if (a.own or false) ~= (b.own or false) then return a.own or false end
        if (a.why ~= nil) ~= (b.why ~= nil) then return a.why ~= nil end
        if a.fee ~= b.fee then return a.fee > b.fee end
        return a.name < b.name
    end)
    return out
end

-- Watch list -----------------------------------------------------------------

function ns.WatchCount()
    local count = 0
    for _ in pairs(ns.db.watchZones) do count = count + 1 end
    for _ in pairs(ns.db.watchPlaces) do count = count + 1 end
    return count
end

function ns.WatchZone(map, on)
    ns.db.watchZones[map] = on and true or nil
    ns.Tick()
    ns.Refresh()
end

function ns.WatchPlace(place, on)
    ns.db.watchPlaces[place.key] = on and { map = place.map, x = place.x, y = place.y, placeName = place.name } or nil
    ns.Tick()
    ns.Refresh()
end

-- A spot picked on the map, for a place the game has no name for.
function ns.WatchSpot(map, x, y)
    local key = ("X%d:%d:%d"):format(map, x * 1000, y * 1000)
    local place = { map = map, x = x, y = y, area = ns.AreaAt(map, x, y) }
    ns.db.watchPlaces[key] = place
    ns.Print(("%s: %s"):format(L["Watched"], ns.Where(place)))
    ns.Tick()
    ns.Refresh()
end

function ns.ClearWatch()
    ns.db.watchZones, ns.db.watchPlaces = {}, {}
    ns.Tick()
    ns.Refresh()
end

-- Own request ----------------------------------------------------------------

local function EncodeWant(want)
    return table.concat({ "W", WANT_BEAT * 2 + 30, want.map, math.floor(want.x * 10000 + 0.5), math.floor(want.y * 10000 + 0.5),
        math.floor(want.fee or 0), want.area or 0, want.test and 1 or 0, Side() }, "\t")
end

function ns.DecodeWant(msg)
    local tag, ttl, map, x, y, fee, area, test, side = strsplit("\t", msg)
    if tag ~= "W" or side ~= Side() then return end
    ttl, map, x, y, fee = tonumber(ttl), tonumber(map), tonumber(x), tonumber(y), tonumber(fee)
    if not (ttl and map and x and y and fee) or x < 0 or x > 10000 or y < 0 or y > 10000 or fee < 0 then return end
    -- A map this client does not know could not be shown or matched.
    if map ~= math.floor(map) or not C_Map.GetMapInfo(map) then return end
    area = tonumber(area) or 0
    if area < 0 or area > 1e7 then area = 0 end
    return { kind = "W", ttl = math.max(30, math.min(ttl, 900)), map = map, x = x / 10000, y = y / 10000,
        fee = math.min(math.floor(fee), ns.FEE_MAX), area = math.floor(area), test = test == "1" or nil }
end

local function WantSig(entry)
    return table.concat({ entry.test and "T" or "", entry.map, math.floor(entry.x * 1000), math.floor(entry.y * 1000), entry.fee }, "\t")
end

function ns.PostWant(map, x, y, fee)
    -- The warlock's invite could not be taken.
    if IsInGroup() then return ns.Print(L["Leave your group first."]) end
    if ns.want then ns.CancelWant() end
    local now = GetTime()
    local want = { name = ns.me, kind = "W", own = true, map = map, x = x, y = y, area = ns.AreaAt(map, x, y),
        fee = math.max(0, math.min(math.floor(fee or 0), ns.FEE_MAX)), time = now, seen = now, ttl = 1e9, state = "OPEN",
        test = ns.testMode or nil }
    ns.want, ns.wanted[ns.me] = want, want
    sentAt, answerAt = 0, nil
    ns.Tick()
    ns.Refresh()
    return want
end

function ns.CancelWant()
    local want = ns.want
    if not want then return end
    ns.want, ns.wanted[ns.me] = nil, nil
    if want.state == "OPEN" then
        ns.Broadcast("V")
    elseif want.taker then
        ns.Send("C", "WHISPER", want.taker.live)
    end
    ns.Refresh()
end

-- Jobs: accepted requests, kept across a relog -------------------------------

local function JobList()
    local list = ns.db.jobs[Realm()]
    if not list then
        list = {}
        ns.db.jobs[Realm()] = list
    end
    return list
end

function ns.Jobs()
    local out = {}
    for _, job in pairs(JobList()) do out[#out + 1] = job end
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.name < b.name
    end)
    return out
end

function ns.JobInvite(name)
    local job = JobList()[name]
    if not job or job.lock ~= ns.me then return end
    if not (ns.Grouped(name) or ns.CanInvite()) then return ns.Print(L["You cannot invite in this group."]) end
    ns.Invite(name)
end

function ns.JobDone(name)
    JobList()[name] = nil
    ns.Refresh()
end

-- The poster logged off: nothing left to do.
function ns.JobGone(name)
    local changed = false
    if JobList()[name] then
        JobList()[name] = nil
        changed = true
    end
    local entry = ns.wanted[name]
    if entry and not entry.own and not entry.fake then
        ns.wanted[name] = nil
        changed = true
    end
    return changed
end

-- Taking ---------------------------------------------------------------------

-- The warlock closest to the spot; the one played when none is close.
local function BestLock(entry)
    local here = HereSpot()
    local best, bestDist
    for _, lock in ipairs(ns.AllWarlocks()) do
        local spot = lock.here and here or (not lock.here and lock) or nil
        local dist = spot and Yards(entry, spot) or nil
        if not best or (dist and (not bestDist or dist < bestDist)) then best, bestDist = lock, dist or bestDist end
    end
    return best
end

function ns.CanTake(entry)
    return entry ~= nil and not entry.own and not entry.state and #ns.AllWarlocks() > 0
end

function ns.Take(name)
    local entry = ns.wanted[name]
    if not entry or entry.own or entry.state then return end
    local lock = BestLock(entry)
    if not lock then return ns.Print(L["Needs a warlock."]) end
    if entry.fake then
        ns.wanted[name] = nil
        ns.Print(("%s: %s %s"):format(name, L["Accepted"], ns.Money(entry.fee)))
        return ns.Refresh()
    end
    if lock.here and not (ns.Grouped(name) or ns.CanInvite()) then return ns.Print(L["You cannot invite in this group."]) end
    entry.state, entry.takeAt, entry.lock = "TAKING", GetTime(), lock.name
    ns.Send("T\t" .. lock.name, "WHISPER", name)
    ns.Refresh()
end

function ns.HideWanted(name)
    local entry = ns.wanted[name]
    if entry then entry.hidden = true end
    ns.Refresh()
end

-- Poster: someone takes the request. The first one gets it.
local function OnTake(name, lock)
    local want = ns.want
    if type(lock) ~= "string" or lock == "" or #lock > 48 or lock:find("[%c|]") then lock = name end
    -- Grouped with someone else meanwhile: the invite would bounce.
    if want and want.state == "OPEN" and IsInGroup() and not ns.Grouped(name) then
        ns.Send("N\tW", "WHISPER", name)
    elseif want and want.state == "OPEN" then
        want.state, want.time = "ACCEPTED", GetTime()
        want.taker = { name = name, lock = lock, live = name }
        ns.Send("Y\tW", "WHISPER", name)
        ns.Broadcast("V")
        -- The warlock is the one who summons and is paid.
        ns.Log(lock, "W", "C", want.fee, ns.Where(want))
        ns.Alert(("%s: %s"):format(lock ~= name and ("%s (%s)"):format(name, lock) or name, L["Accepted"]))
        ns.Refresh()
    elseif want and want.taker and (name == want.taker.name or name == want.taker.lock) then
        -- The warlock logged in, or asks again.
        want.taker.live = name
        ns.Send("Y\tW", "WHISPER", name)
    else
        ns.Send("N\tW", "WHISPER", name)
    end
end

local function OnTakeReply(name, yes)
    local entry = ns.wanted[name]
    if entry and entry.state == "TAKING" then
        ns.wanted[name] = nil
        if yes then
            JobList()[name] = { name = name, lock = entry.lock, map = entry.map, x = entry.x, y = entry.y, area = entry.area,
                fee = entry.fee, at = Wall() }
            ns.Print(("%s: %s %s"):format(name, L["Accepted"], ns.Money(entry.fee)))
            ns.Log(name, "W", "P", entry.fee, ns.Where(entry))
            if entry.lock == ns.me then ns.Invite(name) else ns.Print(L["Log in on %s."]:format(entry.lock)) end
        else
            ns.Print(("%s: %s"):format(name, L["Declined"]))
        end
        return ns.Refresh()
    end
    -- The check after a relog.
    local job = JobList()[name]
    if not job or job.lock ~= ns.me then return end
    if yes then
        if ns.Grouped(name) or ns.CanInvite() then ns.Invite(name) end
    else
        JobList()[name] = nil
        ns.Print(("%s: %s"):format(name, L["Withdrawn"]))
    end
    ns.Refresh()
end

local function OnWanted(name, msg)
    local entry = ns.DecodeWant(msg)
    if not entry then return end
    local old = ns.wanted[name]
    if old and (old.own or old.fake) then return end
    if entry.test and not ns.testMode then
        if old then
            ns.wanted[name] = nil
            ns.Refresh()
        end
        return
    end
    entry.name, entry.seen, entry.sig = name, GetTime(), WantSig(entry)
    if old and old.sig == entry.sig then
        old.seen, old.ttl = entry.seen, entry.ttl
        return
    end
    if not old then
        local count = 0
        for _ in pairs(ns.wanted) do count = count + 1 end
        if count >= WANTED_MAX then return end
    end
    -- Posting anew means whatever was agreed before is over.
    JobList()[name] = nil
    ns.wanted[name] = entry
    local now = GetTime()
    if now - alertedAt >= ALERT_EVERY and ns.Listening() and Mark(entry, ns.AllWarlocks(), HereSpot()) and ns.MayAlert(name) then
        alertedAt = now
        local text = ("%s: %s"):format(name, L["Summon to %s"]:format(ns.Where(entry)))
        if entry.fee > 0 then text = ("%s %s"):format(text, ns.Money(entry.fee)) end
        ns.Alert(text)
    end
    ns.OffersChanged()
end

-- Broadcasts. Returns true when the message was one of these.
function ns.WantedBroadcast(name, tag, msg)
    if tag == "W" then
        OnWanted(name, msg)
    elseif tag == "V" then
        local entry = ns.wanted[name]
        -- A take under way is settled by the whispered answer, which may still be on its way.
        if entry and not entry.own and not entry.fake and entry.state ~= "TAKING" then
            ns.wanted[name] = nil
            ns.OffersChanged()
        end
    elseif tag == "H" or tag == "Q" then
        local want = ns.want
        if want and want.state == "OPEN" and not answerAt and GetTime() - sentAt > WANT_ANSWER then
            answerAt = GetTime() + 1 + math.random() * 5
            C_Timer.After(answerAt - GetTime() + 0.1, ns.Tick)
        end
        return tag == "H"
    else
        return false
    end
    return true
end

-- Whispers. Returns true when the message was one of these.
function ns.WantedWhisper(name, tag, a)
    if tag == "T" then
        OnTake(name, a)
    elseif (tag == "Y" or tag == "N") and a == "W" then
        OnTakeReply(name, tag == "Y")
    elseif tag == "C" and JobList()[name] then
        JobList()[name] = nil
        ns.Print(("%s: %s"):format(name, L["Withdrawn"]))
        ns.Refresh()
    else
        return false
    end
    return true
end

-- The channel was just joined: the request goes out again, and listeners ask what is open.
function ns.WantedJoined()
    sentAt = 0
    if ns.Listening() then ns.Broadcast("H") end
end

function ns.WantedTick(now)
    local changed = false
    local want = ns.want
    if want then
        local here = HereSpot()
        local dist = here and Yards(want, here) or nil
        if dist and dist <= ARRIVED then
            if want.taker then ns.LogDone(want.taker.lock, "W", "C") end
            ns.CancelWant()
            ns.Print(L["Arrived"])
            changed = true
        elseif now - want.time > WANT_TTL then
            ns.CancelWant()
            ns.Print(("%s: %s"):format(L["Wanted"], L["Expired"]))
            changed = true
        elseif want.state == "OPEN" and (now - sentAt >= WANT_BEAT or (answerAt and now >= answerAt)) then
            ns.wantMsg = EncodeWant(want)
            ns.Broadcast(ns.wantMsg)
            sentAt, answerAt = now, nil
        end
    end
    for name, entry in pairs(ns.wanted) do
        if not entry.own and now - entry.seen > entry.ttl and entry.state ~= "TAKING" then
            ns.wanted[name] = nil
            changed = true
        elseif entry.state == "TAKING" and now - entry.takeAt > TAKE_WAIT then
            entry.state, entry.lock = nil, nil
            changed = true
        end
    end
    local wall = Wall()
    for name, job in pairs(JobList()) do
        if wall - job.at > JOB_TTL then
            JobList()[name] = nil
            changed = true
        end
    end
    if now - parkedAt > PARK_GAP then
        parkedAt = now
        ns.Park()
    end
    -- After a relog onto the warlock: is the request still open?
    if not asked then
        asked = true
        for name, job in pairs(JobList()) do
            if job.lock == ns.me then ns.Send("T\t" .. ns.me, "WHISPER", name) end
        end
    end
    return changed
end

function ns.WantedGoodbye()
    ns.Park()
    if ns.want and ns.want.state == "OPEN" then ns.Broadcast("V") end
end

-- Made-up requests around the player, to try the list alone.
function ns.AddTestWanted()
    local zones = C_Map.GetMapChildrenInfo(ns.HomeMap(), 3, false) or {}
    if #zones == 0 then return end
    local now = GetTime()
    for index = 1, 6 do
        local zone = zones[math.random(math.min(#zones, 6))]
        local name = "Seeker" .. index
        ns.wanted[name] = { name = name, kind = "W", map = zone.mapID, x = 0.2 + math.random() * 0.6, y = 0.2 + math.random() * 0.6,
            fee = math.random(0, 20) * 5000, area = 0, seen = now, ttl = 1e9, fake = true }
    end
    ns.Refresh()
end

function ns.ClearTestWanted()
    for name, entry in pairs(ns.wanted) do
        if entry.fake or entry.test then ns.wanted[name] = nil end
    end
    if ns.want and ns.want.test then ns.CancelWant() end
end
