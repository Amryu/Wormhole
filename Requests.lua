local _, ns = ...
local L = ns.L

-- A light list to keep open while playing: requests for a warlock or mage, calls for a clicker.
-- It is opened by hand (minimap button, My Offer, /wf requests) unless the player wants it to pop up.
local ROWS = 16
local ROW_H = 24
local WIDTH, HEIGHT = 340, 190
local frame

local function Entries()
    local clicker = ns.char.kind == "C"
    local list = {}
    for _, entry in pairs(clicker and ns.calls or ns.incoming) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.name < b.name
    end)
    return list, clicker
end

function ns.UpdateRequests()
    if not (frame and frame:IsShown()) then return end
    local list, clicker = Entries()
    local kind = ns.char.kind
    frame.title:SetText(clicker and L["Clicker Jobs"] or L["Requests"])
    for index, row in ipairs(frame.rows) do
        local entry = list[index]
        row:SetShown(entry ~= nil)
        if entry then
            row.name = entry.name
            if clicker then
                local dist = entry.dist and ("  %d %s"):format(entry.dist, L["yd"]) or ""
                row.text:SetText(("%s  |cffffffff%s|r%s"):format(entry.name, ns.Money(entry.pay), dist))
                row.accept:SetEnabled(not entry.state)
            else
                row.text:SetText(("%s  |cffffffff%s|r"):format(entry.name, ns.RequestLabel(entry.kind, entry.arg)))
                row.accept:SetEnabled(true)
            end
            row.decline:SetText(clicker and (HIDE or "Hide") or (DECLINE or "Decline"))
        end
    end
    local offer = ns.offers[ns.me]
    local live = ns.IsLive()
    local warlock = kind == "S" and live and offer ~= nil
    -- As many rows as the height the player gave the window holds.
    local fit = math.max(1, math.min(ROWS, math.floor((frame:GetHeight() - 26 - (warlock and 28 or 0) - 34) / ROW_H)))
    for index = fit + 1, ROWS do frame.rows[index]:Hide() end
    frame.more:SetText(#list > fit and ("+%d"):format(#list - fit) or "")
    frame.empty:SetShown(#list == 0)
    frame.empty:SetText(not live and L["Inactive"] or clicker and L["No Jobs"] or L["No Requests"])

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
    frame.declineAll:SetEnabled(#list > 0)
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
    local f = CreateFrame("Frame", "WayfarerRequestsFrame", UIParent)
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
            if ns.char.kind == "C" then ns.Dismiss(row.name) else ns.Answer(row.name, false) end
            ns.UpdateRequests()
        end)
        row.accept = Button(row, 72, ACCEPT or "Accept")
        row.accept:SetPoint("RIGHT", row.decline, "LEFT", -4, 0)
        row.accept:SetScript("OnClick", function()
            if ns.char.kind == "C" then ns.Apply(row.name) else ns.Answer(row.name, true) end
            ns.UpdateRequests()
        end)
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
