local _, ns = ...
local L = ns.L

-- Ledger: every agreed service, what was actually traded with that player, and whether the service was seen
-- to happen. Kept per account. Only trades with a service partner are recorded.
--
-- A record: t = wall clock, me = own character, realm, who = the other player, kind = S, P, W (summon to a spot)
-- or A (clicker), role = "P" provided or "C" bought, fee = agreed, arg = portal spell or place text,
-- paid = copper traded (positive = received), done = seen to complete.

local LEDGER_MAX = 300
local SAME = 600           -- an agreement repeated this soon is the same service
local PAY_WINDOW = 7200    -- a trade this long after the agreement still belongs to it
local DONE_WINDOW = 1800

local Wall = time or os.time

local function Realm()
    return (GetRealmName and GetRealmName()) or ""
end

local function Find(test, window)
    local list, now, realm = ns.db.ledger, Wall(), Realm()
    for index = #list, 1, -1 do
        local rec = list[index]
        if now - rec.t > window then return end
        if rec.realm == realm and test(rec) then return rec end
    end
end

function ns.Log(who, kind, role, fee, arg)
    if type(who) ~= "string" or who == "" then return end
    local old = Find(function(rec) return rec.who == who and rec.kind == kind and rec.role == role and not rec.done end, SAME)
    if old then
        old.fee, old.arg = fee or 0, arg
        return old
    end
    local list = ns.db.ledger
    local rec = { t = Wall(), me = ns.me, realm = Realm(), who = who, kind = kind, role = role, fee = math.floor(fee or 0), arg = arg }
    list[#list + 1] = rec
    while #list > LEDGER_MAX do table.remove(list, 1) end
    ns.Refresh()
    return rec
end

-- The latest open record that fits is marked as seen to complete. Any of who, kinds and role may be nil.
function ns.LogDone(who, kinds, role, arg)
    local rec = Find(function(rec)
        return not rec.done and (not who or rec.who == who) and (not role or rec.role == role)
            and (not kinds or kinds:find(rec.kind, 1, true) ~= nil) and (arg == nil or rec.arg == arg)
    end, DONE_WINDOW)
    if not rec then return false end
    rec.done = true
    ns.Refresh()
    return true
end

-- Money that changed hands in a finished trade; net is positive when received.
function ns.LogPaid(who, net)
    if not who or not net or net == 0 then return end
    -- The service still unpaid first, else the latest one with this player.
    local rec = Find(function(rec) return rec.who == who and not rec.paid end, PAY_WINDOW)
        or Find(function(rec) return rec.who == who end, PAY_WINDOW)
    if not rec then return end
    rec.paid = (rec.paid or 0) + net
    -- A clicker has nothing else to show for the job.
    if rec.kind == "A" and rec.role == "P" and rec.paid > 0 then rec.done = true end
    ns.Refresh()
    return rec
end

-- Newest first, with what was earned and spent in all.
function ns.Ledger()
    local out, earned, spent = {}, 0, 0
    local list = ns.db.ledger
    for index = #list, 1, -1 do
        local rec = list[index]
        out[#out + 1] = rec
        if (rec.paid or 0) > 0 then earned = earned + rec.paid elseif (rec.paid or 0) < 0 then spent = spent - rec.paid end
    end
    return out, earned, spent
end

function ns.ClearLedger()
    ns.db.ledger = {}
    ns.Refresh()
end

-- Announcements --------------------------------------------------------------
-- Lines in party or raid chat, each kind switched in the options. Chat takes no icons, so money is spelled out.

local ANNOUNCE_KEEP = 60    -- an invite is announced once the group exists, within this time

function ns.PlainMoney(copper)
    copper = math.floor(math.abs(copper or 0) + 0.5)
    local parts = {}
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    if gold > 0 then parts[#parts + 1] = gold .. (GOLD_AMOUNT_SYMBOL or "g") end
    if silver > 0 then parts[#parts + 1] = silver .. (SILVER_AMOUNT_SYMBOL or "s") end
    if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. (COPPER_AMOUNT_SYMBOL or "c") end
    return table.concat(parts, " ")
end

local function Say(text)
    if not IsInGroup() or not SendChatMessage then return false end
    pcall(SendChatMessage, ("[Wormhole] %s"):format(text):sub(1, 250), IsInRaid() and "RAID" or "PARTY")
    return true
end

local function ServiceLine(rec)
    local what = rec.kind == "P" and ns.PortalName(rec.arg) or rec.kind == "A" and L["Clicker"]
        or rec.kind == "W" and rec.arg and ("%s: %s"):format(L["Summon"], rec.arg) or L["Summon"]
    return rec.fee > 0 and ("%s, %s"):format(what, ns.PlainMoney(rec.fee)) or what
end

-- A first invite goes out before there is a group to tell, so the line waits for the group.
local waiting = {}
function ns.AnnounceInvite(name)
    if not ns.db.announceInvite then return end
    local rec = Find(function(rec) return rec.who == name and not rec.done end, SAME)
    local text = ("%s %s"):format(L["Invited"], name)
    if rec then text = ("%s: %s"):format(text, ServiceLine(rec)) end
    if not Say(text) then waiting[name] = { text = text, at = GetTime() } end
end

function ns.AnnounceTick(now)
    for name, line in pairs(waiting) do
        if now - line.at > ANNOUNCE_KEEP then
            waiting[name] = nil
        elseif ns.Grouped(name) and Say(line.text) then
            waiting[name] = nil
        end
    end
end

-- Trades and completion ------------------------------------------------------

local partner, give, got = nil, 0, 0
local ritualTarget
local entered = false

local function OnEvent(_, event, a, b, c, d)
    if event == "TRADE_SHOW" then
        partner = UnitName("NPC")
        give, got = 0, 0
    elseif event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_MONEY_CHANGED" or event == "PLAYER_TRADE_MONEY" then
        give = tonumber(GetPlayerTradeMoney and GetPlayerTradeMoney()) or give
        got = tonumber(GetTargetTradeMoney and GetTargetTradeMoney()) or got
    elseif event == "UI_INFO_MESSAGE" then
        if partner and b ~= nil and b == ERR_TRADE_COMPLETE then
            local net = got - give
            if ns.LogPaid(partner, net) and ns.db.announceTrade then
                Say(net > 0 and L["%s paid %s"]:format(partner, ns.PlainMoney(net)) or L["Paid %s: %s"]:format(partner, ns.PlainMoney(net)))
            end
            partner = nil
        end
    elseif event == "TRADE_REQUEST_CANCEL" then
        partner = nil
    elseif event == "UNIT_SPELLCAST_SENT" then
        -- unit, target, cast, spell
        if a == "player" and d == ns.SUMMON_SPELL then ritualTarget = b and Ambiguate(b, "none") or nil end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- unit, cast, spell
        if a ~= "player" then return end
        if c == ns.SUMMON_SPELL then
            if ns.db.announceCast and ritualTarget then Say(L["Summoning %s"]:format(ritualTarget)) end
            if ritualTarget then ns.LogDone(ritualTarget, "SW", "P") end
            -- The clickers hired for it did their part.
            while ns.LogDone(nil, "A", "C") do end
            ritualTarget = nil
        else
            for _, id in ipairs(ns.KnownPortals()) do
                if id == c then
                    if ns.db.announceCast then Say(ns.SpellName(id) or ns.PortalName(id)) end
                    while ns.LogDone(nil, "P", "P", id) do end
                end
            end
        end
    elseif event == "CONFIRM_SUMMON" then
        local who
        pcall(function() who = C_SummonInfo.GetSummonConfirmSummoner() end)
        if type(who) == "string" then ns.LogDone(Ambiguate(who, "none"), "SW", "C") end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A loading screen after a portal was agreed: the customer went through.
        if entered then ns.LogDone(nil, "P", "C") end
        entered = true
    end
end

function ns.StartLedger()
    local frame = CreateFrame("Frame")
    for _, event in ipairs({ "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_MONEY_CHANGED", "PLAYER_TRADE_MONEY", "TRADE_REQUEST_CANCEL", "UI_INFO_MESSAGE",
        "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "CONFIRM_SUMMON", "PLAYER_ENTERING_WORLD" }) do
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", OnEvent)
    ns.ledgerFrame = frame
end
