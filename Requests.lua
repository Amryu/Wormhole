local _, ns = ...
local L = ns.L

-- A light list to keep open while playing: requests for a warlock or mage, calls for a clicker.
-- It is opened by hand (minimap button, My Offer, /wh requests) unless the player wants it to pop up.
local ROWS = 16
local ROW_H = 24
local WIDTH, HEIGHT = 340, 190
local frame

-- What waits, in the order it is dealt with: requests or clicker jobs, accepted summons to a spot, the own
-- request for one, then the wanted summons that concern this account.
local function Entries()
    local clicker = ns.char.kind == "C"
    local list = {}
    for _, entry in pairs(clicker and ns.calls or ns.incoming) do list[#list + 1] = { type = clicker and "call" or "in", entry = entry, time = entry.time } end
    table.sort(list, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.entry.name < b.entry.name
    end)
    for _, job in ipairs(ns.Jobs()) do list[#list + 1] = { type = "job", entry = job } end
    if ns.want then list[#list + 1] = { type = "own", entry = ns.want } end
    local matched = ns.Matched()
    table.sort(matched, function(a, b)
        if a.seen ~= b.seen then return a.seen < b.seen end
        return a.name < b.name
    end)
    for _, entry in ipairs(matched) do list[#list + 1] = { type = "want", entry = entry } end
    return list, clicker
end

local ARROW = "|cff808080>|r "

local function DrawRow(row, item)
    local entry = item.entry
    row.type, row.name, row.entry = item.type, entry.name, entry
    row.accept:Show()
    row.accept:SetText(ACCEPT or "Accept")
    row.accept:SetEnabled(true)
    row.decline:SetText(DECLINE or "Decline")
    if item.type == "call" then
        local dist = entry.dist and ("  %d %s"):format(entry.dist, L["yd"]) or ""
        row.text:SetText(("%s  |cffffffff%s|r%s"):format(entry.name, ns.Money(entry.pay), dist))
        row.accept:SetEnabled(not entry.state)
        row.decline:SetText(HIDE or "Hide")
    elseif item.type == "in" then
        row.text:SetText(("%s  |cffffffff%s|r"):format(entry.name, ns.RequestLabel(entry.kind, entry.arg)))
    elseif item.type == "want" then
        local tip = entry.fee > 0 and ("  " .. ns.Money(entry.fee)) or ""
        row.text:SetText(("%s  %s|cffffffff%s|r%s"):format(entry.name, ARROW, ns.Where(entry), tip))
        row.accept:SetEnabled(ns.CanTake(entry))
        row.decline:SetText(HIDE or "Hide")
    elseif item.type == "job" then
        local mine = entry.lock == ns.me
        row.text:SetText(("|cff40ff40%s|r  %s|cffffffff%s|r%s"):format(entry.name, ARROW, ns.Where(entry), mine and "" or ("  (%s)"):format(entry.lock)))
        row.accept:SetText(INVITE or "Invite")
        row.accept:SetEnabled(mine)
        row.decline:SetText(DONE or "Done")
    else
        local taker = entry.taker
        local state = taker and ("|cff40ff40%s|r: %s"):format(L["Accepted"], taker.lock) or ("|cffffd100%s|r"):format(L["Open"])
        row.text:SetText(("%s|cffffffff%s|r  %s"):format(ARROW, ns.Where(entry), state))
        row.accept:Hide()
        row.decline:SetText(CANCEL or "Cancel")
    end
end

local function RowTip(row)
    local entry = row.entry
    if not entry or not (row.type == "want" or row.type == "job" or row.type == "own") then return end
    GameTooltip:SetOwner(row, "ANCHOR_TOPLEFT")
    GameTooltip:AddDoubleLine(entry.name, (entry.fee or 0) > 0 and ns.Money(entry.fee) or "", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine(L["Summon to %s"]:format(ns.Where(entry)), 1, 0.82, 0, true)
    local reason = row.type == "want" and ns.ReasonText(entry)
    if reason then GameTooltip:AddLine(reason, 0.25, 1, 0.25) end
    if row.type == "job" and entry.lock ~= ns.me then GameTooltip:AddLine(L["Log in on %s."]:format(entry.lock), 1, 0.5, 0.25) end
    GameTooltip:Show()
end

function ns.UpdateRequests()
    if not (frame and frame:IsShown()) then return end
    local list, clicker = Entries()
    local kind = ns.char.kind
    frame.title:SetText(clicker and L["Clicker Jobs"] or L["Requests"])
    for index, row in ipairs(frame.rows) do
        local item = list[index]
        row:SetShown(item ~= nil)
        if item then DrawRow(row, item) end
    end
    local offer = ns.offers[ns.me]
    local live = ns.IsLive()
    local warlock = kind == "S" and live and offer ~= nil
    -- As many rows as the height the player gave the window holds.
    local fit = math.max(1, math.min(ROWS, math.floor((frame:GetHeight() - 26 - (warlock and 28 or 0) - 34) / ROW_H)))
    for index = fit + 1, ROWS do frame.rows[index]:Hide() end
    frame.more:SetText(#list > fit and ("+%d"):format(#list - fit) or "")
    frame.empty:SetShown(#list == 0)
    frame.empty:SetText(not (live or ns.Listening()) and L["Inactive"] or clicker and L["No Jobs"] or L["No Requests"])

    -- Warlock: clickers at hand, and the call for more.
    frame.clickers:SetShown(warlock)
    frame.call:SetShown(warlock)
    if warlock then
        local ready = offer.ready or 0
        frame.clickers:SetText(("%s: %s%d/2|r   %s"):format(L["Clickers"], ready >= 2 and "|cff40ff40" or "|cffff9040", ready, ns.Money(ns.char.clickerPay)))
        local call = ns.call
        frame.call:SetText(call and ("%s %d/%d"):format(L["Searching"], call.count, call.need) or L["Request Clickers"])
        frame.call:SetEnabled(not call and ready < 2)
    end
    frame.declineAll:SetShown(not clicker)
    frame.declineAll:SetEnabled(next(ns.incoming) ~= nil)
    frame.off:SetText(ns.char.active and L["Deactivate"] or L["Activate"])
    if ns.FlashMinimapButton then ns.FlashMinimapButton(false) end
end

local function Place(f)
    local pos = ns.db.requestsPos
    f:ClearAllPoints()
    if pos then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
    else
        f:SetPoint("TOPLEFT", UIParent, "CENTER", 260, 160)
    end
end

local function Build()
    local f = CreateFrame("Frame", "WormholeRequestsFrame", UIParent)
    local size = ns.db.requestsSize
    f:SetSize(size and size[1] or WIDTH, size and size[2] or HEIGHT)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(280, 110, 700, 26 + ROWS * ROW_H + 62) elseif f.SetMinResize then f:SetMinResize(280, 110) end
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.db.requestsPos = { self:GetLeft(), self:GetTop() }
        Place(self)
    end)
    Place(f)
    local back = f:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(0, 0, 0, 0.45)
    local head = f:CreateTexture(nil, "BORDER")
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:SetHeight(22)
    head:SetColorTexture(0, 0, 0, 0.35)

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 8, -5)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local function Button(parent, width, text)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(width, 22)
        button:SetText(text or "")
        return button
    end

    f.rows = {}
    for index = 1, ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 8, -26 - (index - 1) * ROW_H)
        row:SetPoint("RIGHT", -8, 0)
        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.text:SetPoint("LEFT")
        row.text:SetPoint("RIGHT", -152, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        -- Declines a request; for a clicker it only hides the job.
        row.decline = Button(row, 72)
        row.decline:SetPoint("RIGHT")
        row.decline:SetScript("OnClick", function()
            if row.type == "call" then ns.Dismiss(row.name)
            elseif row.type == "want" then ns.HideWanted(row.name)
            elseif row.type == "job" then ns.JobDone(row.name)
            elseif row.type == "own" then ns.CancelWant()
            else ns.Answer(row.name, false) end
            ns.UpdateRequests()
        end)
        row.accept = Button(row, 72, ACCEPT or "Accept")
        row.accept:SetPoint("RIGHT", row.decline, "LEFT", -4, 0)
        row.accept:SetScript("OnClick", function()
            if row.type == "call" then ns.Apply(row.name)
            elseif row.type == "want" then ns.Take(row.name)
            elseif row.type == "job" then ns.JobInvite(row.name)
            elseif row.type == "in" then ns.Answer(row.name, true) end
            ns.UpdateRequests()
        end)
        row:EnableMouse(true)
        row:SetScript("OnEnter", RowTip)
        row:SetScript("OnLeave", GameTooltip_Hide)
        f.rows[index] = row
    end
    f.empty = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    f.empty:SetPoint("TOPLEFT", 8, -31)
    f.more = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.more:SetPoint("LEFT", f.title, "RIGHT", 8, 0)

    f.clickers = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.clickers:SetPoint("BOTTOMLEFT", 8, 39)
    f.call = Button(f, 150)
    f.call:SetPoint("BOTTOMRIGHT", -8, 34)
    f.call:SetScript("OnClick", function()
        ns.CallClickers()
        ns.UpdateRequests()
    end)
    f.declineAll = Button(f, 120, L["Decline All"])
    f.declineAll:SetPoint("BOTTOMLEFT", 8, 6)
    f.declineAll:SetScript("OnClick", function()
        ns.DeclineAll()
        ns.UpdateRequests()
    end)
    -- Switching the service off declines everything that waits.
    f.off = Button(f, 120)
    f.off:SetPoint("BOTTOMRIGHT", -20, 6)
    f.off:SetScript("OnClick", function()
        ns.SetActive(not ns.char.active)
        ns.UpdateRequests()
        ns.UpdateWindow()
    end)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT")
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        ns.db.requestsSize = { f:GetWidth(), f:GetHeight() }
        ns.db.requestsPos = { f:GetLeft(), f:GetTop() }
        Place(f)
        ns.UpdateRequests()
    end)
    f:SetScript("OnSizeChanged", function() ns.UpdateRequests() end)
    f:SetScript("OnShow", ns.UpdateRequests)
    f:Hide()
    return f
end

function ns.ShowRequests()
    if not frame then
        local ok, result = pcall(Build)
        if not ok then return ns.Print(tostring(result)) end
        frame = result
    end
    frame:Show()
    ns.UpdateRequests()
end

function ns.ToggleRequests()
    if frame and frame:IsShown() then frame:Hide() else ns.ShowRequests() end
end

function ns.RequestsShown()
    return frame ~= nil and frame:IsShown()
end
