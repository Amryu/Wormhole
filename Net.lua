local _, ns = ...
local L = ns.L

-- Transport: addon messages on one custom channel, plus YELL for players in range.
-- The servers block a custom channel once many players sit in it, so the channel is only joined while
-- the window is open or an offer is live, and left again a minute later.
--
-- Messages, fields split by tabs:
--   O kind ttl map x y fee a b c note   offer (broadcast). S: a = clickers nearby, b = hiring, c = clicker pay.
--                                       P: a = portal spell IDs, comma separated.
--   X                                   offer withdrawn (broadcast)
--   Q                                   who is offering? (broadcast)
--   K pay map x y test                  a warlock needs clickers (broadcast); E = no longer
--   R type arg                          request (whisper). S summon, P portal (arg = spell), A clicker answering a call
--   Y type / N type                     request accepted / declined (whisper)
--   C                                   request withdrawn (whisper)
-- Wanted.lua adds W, V, H and T for summons to a spot.

local PREFIX = "Wormhole"
local CHANNEL = "WormholeNet"
local BEAT = 60            -- seconds between offer broadcasts
local EDIT_GAP = 5         -- soonest rebroadcast after an edit or move
local ANSWER_GAP = 20      -- a query is answered only when the last broadcast is older
local LEAVE_AFTER = 60
local JOIN_RETRY = 30
local REQUEST_TTL = 180
local REQUEST_GAP = 20
local CALL_TTL = 60        -- how long a call for clickers stays open
local REQUEST_WAIT = 60    -- an unanswered request is withdrawn after this
ns.REQUEST_MAX = 3         -- open requests one player may have
local OFFER_MAX = 2000      -- offers kept; further senders are dropped
local ALERT_GAP = 30        -- one sender alerts at most this often
local FEE_MAX = ns.FEE_MAX
local PAUSE_KEEP = 120       -- requests survive a pause (AFK, instance) this long
local REPLY_GAP = 5          -- one sender is told no at most this often

ns.incoming, ns.outgoing, ns.calls = {}, {}, {}
ns.net = { joined = false, refused = false }

local lastSent, lastSig, answerAt, wasLive = 0, nil, nil, false
local lastStatus, pausedAt
local lastJoin, idleSince, lastQuery = -1000, nil, -1000
local alerted, replied = {}, {}

-- Offers arrive many a second on a busy server; the interface hears of them once a second.
local pending = false
local function OffersChanged()
    if pending then return end
    pending = true
    C_Timer.After(1, function()
        pending = false
        ns.Refresh()
    end)
end
ns.OffersChanged = OffersChanged

-- Whether this sender may sound an alert now.
local function MayAlert(name)
    local now = GetTime()
    if alerted[name] and now - alerted[name] < ALERT_GAP then return false end
    alerted[name] = now
    return true
end
ns.MayAlert = MayAlert

local function ChannelID()
    local id = GetChannelName(CHANNEL)
    if id and id > 0 then return id end
end

local function Send(msg, dist, target)
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, dist, target)
    return ok and (result == nil or result == true or result == 0)
end
ns.Send = Send

local function Broadcast(msg)
    local id = ChannelID()
    if id then ns.net.refused = not Send(msg, "CHANNEL", id) end
    if not IsInInstance() then Send(msg, "YELL") end
end
ns.Broadcast = Broadcast

local function HideChannel()
    local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
    if not remove then return end
    for index = 1, NUM_CHAT_WINDOWS or 10 do
        local chat = _G["ChatFrame" .. index]
        if chat then pcall(remove, chat, CHANNEL) end
    end
end

-- Codec --------------------------------------------------------------------

local function Clean(text)
    return (tostring(text or ""):gsub("[%c|]", " ")):sub(1, ns.NOTE_MAX)
end

function ns.Encode(offer, ttl)
    local a, b, c = 0, 0, 0
    if offer.kind == "S" then
        a, b, c = offer.ready or 0, offer.hire and 1 or 0, offer.pay or 0
    elseif offer.kind == "P" then
        a = table.concat(offer.dests or {}, ",")
    end
    return table.concat({ "O", offer.test and offer.kind:lower() or offer.kind, ttl, offer.map, math.floor(offer.x * 10000 + 0.5), math.floor(offer.y * 10000 + 0.5),
        math.floor(offer.fee or 0), a, b, c, Clean(offer.note) }, "\t")
end

function ns.Decode(msg)
    local tag, kind, ttl, map, x, y, fee, a, b, c, note = strsplit("\t", msg)
    -- A lowercase kind marks a test mode offer.
    local test = kind == "s" or kind == "p" or kind == "c"
    if test then kind = kind:upper() end
    if tag ~= "O" or not (kind == "S" or kind == "P" or kind == "C") then return end
    ttl, map, x, y, fee = tonumber(ttl), tonumber(map), tonumber(x), tonumber(y), tonumber(fee)
    if not (ttl and map and x and y and fee) or x < 0 or x > 10000 or y < 0 or y > 10000 or fee < 0 then return end
    local offer = { kind = kind, ttl = math.max(30, math.min(ttl, 900)), map = map, x = x / 10000, y = y / 10000,
        fee = math.min(math.floor(fee), FEE_MAX), note = Clean(note), test = test or nil }
    if kind == "S" then
        offer.ready = math.max(0, math.min(tonumber(a) or 0, 2))
        offer.hire = b == "1"
        offer.pay = math.max(0, math.min(math.floor(tonumber(c) or 0), FEE_MAX))
    elseif kind == "P" then
        offer.dests = {}
        for id in tostring(a or ""):gmatch("%d+") do
            if #offer.dests < 16 then offer.dests[#offer.dests + 1] = tonumber(id) end
        end
        if #offer.dests == 0 then return end
    end
    return offer
end

-- Offers -------------------------------------------------------------------

local function Count(list)
    local count = 0
    for _ in pairs(list) do count = count + 1 end
    return count
end

-- Broadcasts thin out as offers pile up, so the channel stays quiet.
local function Beat()
    return math.max(BEAT, math.min(300, Count(ns.offers) * 0.4))
end

local lastMsg
local function SendOffer(offer)
    local beat = Beat()
    lastMsg = ns.Encode(offer, math.floor(beat * 2.5))
    Broadcast(lastMsg)
    lastSent, answerAt = GetTime(), nil
    lastSig = ns.Signature(offer)
end

-- What makes an offer worth sending again; position counts in steps of 1% of the map.
function ns.Signature(offer)
    return table.concat({ offer.test and "T" or "", offer.kind, offer.map, math.floor(offer.x * 100), math.floor(offer.y * 100), offer.fee, offer.ready or 0,
        offer.hire and 1 or 0, offer.pay or 0, table.concat(offer.dests or {}, ","), offer.note or "" }, "\t")
end

local function Prune(now)
    local changed = false
    for name, offer in pairs(ns.offers) do
        if not offer.own and now - offer.seen > offer.ttl then
            ns.offers[name] = nil
            changed = true
        end
    end
    for name, request in pairs(ns.outgoing) do
        if request.state == "SENT" and now - request.time > REQUEST_WAIT then
            ns.Cancel(name)
            changed = true
        end
    end
    for name, call in pairs(ns.calls) do
        if now - call.time > CALL_TTL then
            ns.calls[name] = nil
            changed = true
        end
    end
    if ns.call and now - ns.call.time > CALL_TTL then ns.EndCall() end
    for name, time in pairs(alerted) do
        if now - time > ALERT_GAP then alerted[name] = nil end
    end
    for name, time in pairs(replied) do
        if now - time > REPLY_GAP then replied[name] = nil end
    end
    -- Calls are for a clicker on duty only.
    if next(ns.calls) and not (ns.char.kind == "C" and ns.IsLive()) then
        for name in pairs(ns.calls) do ns.calls[name] = nil end
        changed = true
    end
    for _, list in ipairs({ ns.incoming, ns.outgoing }) do
        for name, request in pairs(list) do
            if now - request.time > REQUEST_TTL then
                list[name] = nil
                changed = true
            end
        end
    end
    return changed
end

local function Channel(now)
    local want = ns.Browsing() or ns.IsLive() or ns.WantsChannel()
    local id = ChannelID()
    if want then
        idleSince = nil
        if id and not ns.net.joined then
            ns.net.joined, ns.net.since = true, now
            HideChannel()
            lastSent = 0
            ns.WantedJoined()
            if ns.Browsing() then ns.Query(true) end
        elseif not id then
            ns.net.joined = false
            if now - lastJoin > JOIN_RETRY then
                lastJoin = now
                pcall(JoinChannelByName, CHANNEL)
                C_Timer.After(3, ns.Tick)
            end
        end
    elseif id then
        idleSince = idleSince or now
        if now - idleSince > LEAVE_AFTER then
            pcall(LeaveChannelByName, CHANNEL)
            ns.net.joined, idleSince = false, nil
        end
    else
        ns.net.joined = false
    end
end

-- force: the channel was just joined, so the question goes out even if yell range was asked a moment ago.
function ns.Query(force)
    local now = GetTime()
    if not force and now - lastQuery < 30 then return end
    -- After a full round on the channel every offer has been heard already.
    if ns.net.joined and ns.net.since and now - ns.net.since > Beat() * 1.2 then return end
    lastQuery = now
    Broadcast("Q")
end

local started = false
function ns.Tick()
    if not started then return end
    local now = GetTime()
    -- A clicker only listens; warlocks and mages broadcast an offer.
    local live = ns.IsLive() and ns.char.kind ~= "C"
    local changed = Prune(now)
    Channel(now)
    changed = ns.WantedTick(now) or changed
    ns.AnnounceTick(now)
    if live then
        local offer = ns.OwnOffer()
        if offer then
            offer.seen, offer.ttl = now, 900
            local old = ns.offers[ns.me]
            ns.offers[ns.me] = offer
            local sig = ns.Signature(offer)
            changed = changed or not old or ns.Signature(old) ~= sig
            local since = now - lastSent
            if since >= Beat() or (sig ~= lastSig and since >= EDIT_GAP) or (answerAt and now >= answerAt) then SendOffer(offer) end
        end
    elseif ns.offers[ns.me] then
        ns.offers[ns.me] = nil
        changed = true
    end
    if wasLive and not live then
        Broadcast("X")
        lastSig = nil
        ns.EndCall()
        -- Switched off by hand: everyone waiting is told no. A pause keeps them for a while.
        if not ns.char.active or ns.char.kind == "C" then ns.DeclineAll() else pausedAt = now end
    end
    if live then
        pausedAt = nil
    elseif pausedAt and (not ns.char.active or now - pausedAt > PAUSE_KEEP) then
        pausedAt = nil
        ns.DeclineAll()
    end
    if live ~= wasLive then changed = true end
    wasLive = live
    -- Joining takes a moment and nothing else redraws when it lands.
    local status = ns.NetStatus()
    if status ~= lastStatus then
        lastStatus = status
        changed = true
    end
    if changed then ns.Refresh() end
end

-- Requests -----------------------------------------------------------------

local function Grouped(name)
    return UnitInParty(name) or UnitInRaid(name) or false
end
ns.Grouped = Grouped

-- Whether an invite from this player can go out at all.
function ns.CanInvite()
    if not IsInGroup() then return true end
    if not (UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))) then return false end
    return not (IsInRaid() and GetNumGroupMembers() >= 40)
end

-- Whether this player could take an invite from name: ungrouped, or in that group already.
local function CanJoin(name)
    return not IsInGroup() or Grouped(name)
end

-- Something waits: a sound, a line on screen and a mark on the minimap button. The window only opens
-- by itself when the player asked for that.
function ns.Alert(text)
    if ns.db.sound and PlaySound and SOUNDKIT then pcall(PlaySound, SOUNDKIT.TELL_MESSAGE) end
    if text and ns.db.alertChat then ns.Print(text) end
    if text and ns.db.alertScreen and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage("Wormhole: " .. text, 1, 0.82, 0) end
    if ns.FlashMinimapButton then ns.FlashMinimapButton() end
    if ns.db.autoOpen and ns.ShowRequests then ns.ShowRequests() end
end

local function Invite(name)
    if Grouped(name) then return end
    local invite = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
    if IsInGroup() and not IsInRaid() and GetNumGroupMembers() >= 5 and UnitIsGroupLeader("player") then
        pcall(C_PartyInfo and C_PartyInfo.ConvertToRaid or ConvertToRaid)
        -- A full party refuses the invite until the conversion has landed.
        ns.AnnounceInvite(name)
        return C_Timer.After(1, function() pcall(invite, name) end)
    end
    pcall(invite, name)
    ns.AnnounceInvite(name)
end
ns.Invite = Invite

function ns.RequestLabel(kind, arg)
    if kind == "S" then return L["Summon"] end
    if kind == "P" then return ns.PortalName(arg) end
    return L["Clicker"]
end

function ns.OpenRequests()
    local count = 0
    for _, request in pairs(ns.outgoing) do
        if request.state == "SENT" then count = count + 1 end
    end
    return count
end

function ns.Cancel(name)
    local request = ns.outgoing[name]
    if not request then return end
    ns.outgoing[name] = nil
    if request.state == "SENT" and not (ns.offers[name] and ns.offers[name].fake) then Send("C", "WHISPER", name) end
    ns.Refresh()
end

-- Open requests to players outside the own group are withdrawn.
function ns.RetractAll()
    for name, request in pairs(ns.outgoing) do
        if request.state == "SENT" and not (UnitInParty(name) or UnitInRaid(name)) then ns.Cancel(name) end
    end
end

-- Whether a request to this player may go out: the offer still stands and the last try is not too fresh.
function ns.CanRequest(name)
    local old = ns.outgoing[name]
    return name ~= ns.me and ns.offers[name] ~= nil and not (old and GetTime() - old.time < REQUEST_GAP)
end

function ns.Request(name, kind, arg)
    if not ns.CanRequest(name) then return end
    if ns.OpenRequests() >= ns.REQUEST_MAX then return ns.Print(L["Request Limit Reached"]) end
    if not CanJoin(name) then return ns.Print(L["Leave your group first."]) end
    ns.outgoing[name] = { name = name, kind = kind, arg = arg, time = GetTime(), state = "SENT" }
    if not (ns.offers[name] and ns.offers[name].fake) then
        Send(table.concat({ "R", kind, arg or 0 }, "\t"), "WHISPER", name)
    end
    ns.Refresh()
end

function ns.Answer(name, accept)
    local request = ns.incoming[name]
    if not request then return end
    if accept and not request.fake and not Grouped(name) and not ns.CanInvite() then
        return ns.Print(L["You cannot invite in this group."])
    end
    ns.incoming[name] = nil
    if request.fake then
        ns.Print(("%s: %s"):format(name, accept and L["Accepted"] or L["Declined"]))
        return ns.Refresh()
    end
    Send((accept and "Y\t" or "N\t") .. request.kind, "WHISPER", name)
    if accept then
        -- A clicker is paid by this warlock; a customer pays the fee.
        if request.kind == "A" then ns.Log(name, "A", "C", ns.char.clickerPay)
        else ns.Log(name, request.kind, "P", ns.char.fee[request.kind], request.kind == "P" and request.arg or nil) end
        Invite(name)
        local call = ns.call
        if request.kind == "A" and call and not call.accepted[name] then
            call.accepted[name] = true
            call.count = call.count + 1
            if call.count >= call.need then ns.EndCall() end
        end
    end
    ns.Refresh()
end

function ns.DeclineAll()
    local names = {}
    for name in pairs(ns.incoming) do names[#names + 1] = name end
    for _, name in ipairs(names) do ns.Answer(name, false) end
end

-- Clicker calls ------------------------------------------------------------

-- Warlock: ask clickers in range for the missing clicks. The pay comes out of the warlock's fee.
function ns.CallClickers()
    local offer = ns.offers[ns.me]
    if ns.call or not offer or offer.kind ~= "S" then return end
    local need = 2 - (offer.ready or 0)
    if need <= 0 then return end
    ns.call = { time = GetTime(), need = need, count = 0, accepted = {} }
    Broadcast(table.concat({ "K", math.floor(ns.char.clickerPay or 0), offer.map, math.floor(offer.x * 10000 + 0.5),
        math.floor(offer.y * 10000 + 0.5), ns.testMode and 1 or 0 }, "\t"))
    ns.Refresh()
end

function ns.EndCall()
    if not ns.call then return end
    ns.call = nil
    Broadcast("E")
    -- Clickers still waiting for an answer are told.
    for name, request in pairs(ns.incoming) do
        if request.kind == "A" then
            ns.incoming[name] = nil
            if not request.fake then Send("N\tA", "WHISPER", name) end
        end
    end
    ns.Refresh()
end

local function OnApply(name)
    local call = ns.call
    if not call or call.count >= call.need or call.accepted[name] or not (Grouped(name) or ns.CanInvite()) then
        return Send("N\tA", "WHISPER", name)
    end
    if not ns.char.autoClickers then
        -- The warlock picks: the clicker waits in the request list.
        if not ns.incoming[name] then
            ns.incoming[name] = { name = name, kind = "A", arg = 0, time = GetTime() }
            if MayAlert(name) then ns.Alert(("%s: %s"):format(name, L["Clicker"])) end
            ns.Refresh()
        end
        return
    end
    call.accepted[name] = true
    call.count = call.count + 1
    Send("Y\tA", "WHISPER", name)
    ns.Log(name, "A", "C", ns.char.clickerPay)
    Invite(name)
    ns.Print(("%s: %s"):format(name, L["Clicker"]))
    if call.count >= call.need then ns.EndCall() end
    ns.Refresh()
end

local function InRange(call)
    local here = ns.Here()
    if not here then return false end
    call.dist = ns.Distance(call, here)
    local range = ns.char.range or 300
    if range == 0 then return call.map == here[1] end
    return call.dist ~= nil and call.dist <= range
end

-- Clicker: a warlock calls. Only heard while the clicker service is on, ungrouped and in range.
local function OnCall(name, pay, map, x, y, test)
    if ns.char.kind ~= "C" or not ns.IsLive() or IsInGroup() then return end
    if test == "1" and not ns.testMode then return end
    pay, map, x, y = tonumber(pay), tonumber(map), tonumber(x), tonumber(y)
    if not (pay and map and x and y) or pay < 0 or x < 0 or x > 10000 or y < 0 or y > 10000 then return end
    local call = { name = name, pay = math.floor(pay), map = map, x = x / 10000, y = y / 10000, time = GetTime() }
    if not InRange(call) then return end
    local fresh = not ns.calls[name]
    ns.calls[name] = call
    if fresh and MayAlert(name) then
        local text = ("%s: %s %s"):format(name, L["Clickers Needed"], ns.Money(call.pay))
        ns.Alert(text)
    end
    ns.Refresh()
end

function ns.Apply(name)
    local call = ns.calls[name]
    if not call or call.state then return end
    if not call.fake and not CanJoin(name) then return ns.Print(L["Leave your group first."]) end
    if call.fake then
        ns.calls[name] = nil
        ns.Print(("%s: %s %s"):format(name, L["Accepted"], ns.Money(call.pay)))
    else
        call.state = "APPLIED"
        Send("R\tA\t0", "WHISPER", name)
    end
    ns.Refresh()
end

function ns.Dismiss(name)
    ns.calls[name] = nil
    ns.Refresh()
end

local function OnCallReply(name, accepted)
    local call = ns.calls[name]
    if not call or call.state ~= "APPLIED" then return end
    if accepted then
        ns.Print(("%s: %s %s"):format(name, L["Accepted"], ns.Money(call.pay)))
        ns.Log(name, "A", "P", call.pay)
        -- One job at a time.
        for other in pairs(ns.calls) do ns.calls[other] = nil end
    else
        ns.Print(("%s: %s"):format(name, L["Declined"]))
        ns.calls[name] = nil
    end
    ns.Refresh()
end

-- Whether a request of this kind fits what this player offers right now.
local function Wanted(kind, arg)
    local offer = ns.IsLive() and ns.offers[ns.me]
    if not offer then return false end
    if kind == "S" then return offer.kind == "S" end
    if kind == "P" and offer.kind == "P" then
        for _, id in ipairs(offer.dests) do
            if id == arg then return true end
        end
    end
    return false
end

local function OnRequest(name, kind, arg)
    if kind == "A" then return OnApply(name) end
    arg = tonumber(arg) or 0
    if not Wanted(kind, arg) or Count(ns.incoming) >= 20 then
        if not ns.incoming[name] and (not replied[name] or GetTime() - replied[name] > REPLY_GAP) then
            replied[name] = GetTime()
            Send("N\t" .. tostring(kind), "WHISPER", name)
        end
        return
    end
    local fresh = not ns.incoming[name]
    ns.incoming[name] = { name = name, kind = kind, arg = arg, time = GetTime() }
    if fresh then
        local text = ("%s: %s"):format(name, ns.RequestLabel(kind, arg))
        if ns.char.autoInvite and (Grouped(name) or ns.CanInvite()) then
            if ns.db.alertChat then ns.Print(text) end
            return ns.Answer(name, true)
        end
        if MayAlert(name) then ns.Alert(text) end
    end
    ns.Refresh()
end

local function OnReply(name, accepted)
    local request = ns.outgoing[name]
    if not request or request.state ~= "SENT" then return end
    request.state = accepted and "ACCEPTED" or "DECLINED"
    request.time = GetTime()
    if accepted then
        local offer = ns.offers[name]
        ns.Print(("%s: %s%s"):format(name, L["Accepted"], offer and (" " .. ns.Money(offer.fee)) or ""))
        ns.Log(name, request.kind, "C", offer and offer.fee or 0, request.kind == "P" and request.arg or nil)
    else
        ns.Print(("%s: %s"):format(name, L["Declined"]))
    end
    ns.Refresh()
    -- The request button comes back once a new try is allowed.
    C_Timer.After(REQUEST_GAP + 0.2, ns.Refresh)
end

-- The game says "no player named ..." when a request went to someone who logged off: the offer and the
-- request are gone.
local notFound
local function OnSystem(text)
    if notFound == nil then
        local template = ERR_CHAT_PLAYER_NOT_FOUND_S
        notFound = type(template) == "string" and template:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%s", "(.+)") or false
    end
    local name = notFound and type(text) == "string" and text:match(notFound)
    if not name then return end
    name = Ambiguate(name, "none")
    local changed = ns.JobGone(name)
    if (ns.outgoing[name] or ns.offers[name]) and not (ns.offers[name] and (ns.offers[name].own or ns.offers[name].fake)) then
        ns.outgoing[name], ns.offers[name] = nil, nil
        changed = true
    end
    if changed then ns.Refresh() end
end

function ns.Goodbye()
    if wasLive then Broadcast("X") end
    ns.WantedGoodbye()
end

-- The game may send under a longer name than UnitName gives (a surname). The echo of the own offer
-- shows which, and it is remembered.
local function IsMe(name, msg)
    if name == ns.me or name == ns.char.alias then return true end
    if (msg == lastMsg or msg == ns.wantMsg) and (name:find(ns.me, 1, true) == 1 or ns.me:find(name, 1, true) == 1) then
        ns.char.alias = name
        if ns.offers[name] then
            ns.offers[name] = nil
            ns.Refresh()
        end
        return true
    end
    return false
end

local function OnMessage(msg, dist, sender)
    local name = Ambiguate(sender, "none")
    if IsMe(name, msg) then return end
    if C_FriendList and C_FriendList.IsIgnored and C_FriendList.IsIgnored(name) then return end
    local tag, a, b = strsplit("\t", msg)
    if dist == "WHISPER" then
        if ns.WantedWhisper(name, tag, a) then return end
        if tag == "R" then OnRequest(name, a, b)
        elseif (tag == "Y" or tag == "N") and a == "A" then OnCallReply(name, tag == "Y")
        elseif tag == "Y" then OnReply(name, true)
        elseif tag == "N" then OnReply(name, false)
        elseif tag == "C" and ns.incoming[name] then
            ns.incoming[name] = nil
            ns.Refresh()
        end
        return
    end
    if ns.WantedBroadcast(name, tag, msg) then return end
    if tag == "O" then
        local offer = ns.Decode(msg)
        if not offer then return end
        if offer.test and not ns.testMode then
            -- Whatever this player offered before no longer stands.
            if ns.offers[name] then
                ns.offers[name] = nil
                ns.Refresh()
            end
            return
        end
        offer.name, offer.seen, offer.sig = name, GetTime(), ns.Signature(offer)
        local old = ns.offers[name]
        -- A heartbeat, or the second copy of a broadcast: nothing to redraw.
        if old and old.sig == offer.sig then
            old.seen, old.ttl = offer.seen, offer.ttl
            return
        end
        if not old and Count(ns.offers) >= OFFER_MAX then return end
        ns.offers[name] = offer
        OffersChanged()
    elseif tag == "X" then
        if ns.offers[name] then
            ns.offers[name] = nil
            OffersChanged()
        end
    elseif tag == "K" then
        OnCall(name, a, b, select(4, strsplit("\t", msg)))
    elseif tag == "E" then
        if ns.calls[name] and ns.calls[name].state ~= "APPLIED" then
            ns.calls[name] = nil
            ns.Refresh()
        end
    elseif tag == "Q" then
        -- Spread the answers out; one broadcast answers every query that came in meanwhile.
        -- The more offers, the rarer and the more spread out the answers: with many browsers asking, every
        -- provider would otherwise broadcast at the answer gap instead of the heartbeat.
        local beat = Beat()
        if wasLive and not answerAt and GetTime() - lastSent > math.max(ANSWER_GAP, beat / 2) then
            answerAt = GetTime() + 1 + math.random() * math.max(5, math.min(60, Count(ns.offers) * 0.2))
            C_Timer.After(answerAt - GetTime() + 0.1, ns.Tick)
        end
    end
end

function ns.NetStatus()
    if ns.net.joined and not ns.net.refused then return L["Connected"], 0.25, 1, 0.25 end
    -- The join was asked for and did not happen: offers still travel in yell range.
    if ns.net.joined or (lastJoin > 0 and GetTime() - lastJoin > 8) then return L["Nearby Only"], 1, 0.5, 0.25 end
    return L["Connecting"], 0.6, 0.6, 0.6
end

function ns.StartNet()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("CHAT_MSG_SYSTEM")
    frame:SetScript("OnEvent", function(_, event, prefix, msg, dist, sender)
        if event == "CHAT_MSG_SYSTEM" then return OnSystem(prefix) end
        if prefix == PREFIX and type(msg) == "string" and type(sender) == "string" then OnMessage(msg, dist, sender) end
    end)
    if ChatFrame_AddMessageEventFilter then
        local function Ours(_, _, _, _, _, channelString, _, _, _, _, channelName)
            return (type(channelName) == "string" and channelName:find(CHANNEL, 1, true) ~= nil)
                or (type(channelString) == "string" and channelString:find(CHANNEL, 1, true) ~= nil)
        end
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", Ours)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", Ours)
    end
    -- Wait for the game's own channels, so ours never takes /1.
    C_Timer.After(12, function()
        started = true
        ns.Tick()
        C_Timer.NewTicker(2, ns.Tick)
    end)
end
