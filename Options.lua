local _, ns = ...
local L = ns.L

function ns.InitOptions()
    local category = Settings.RegisterVerticalLayoutCategory("Wormhole")

    local function Proxy(key, varType, label, after)
        local function Get() return ns.db[key] end
        local function Set(value)
            ns.db[key] = value
            if after then after() end
            ns.Tick()
            ns.Refresh()
        end
        return Settings.RegisterProxySetting(category, "WORMHOLE_" .. key:upper(), varType, label, ns.defaults[key], Get, Set)
    end

    Settings.CreateCheckbox(category, Proxy("autoAfk", Settings.VarType.Boolean, L["Pause While AFK"]), L["Hides your offer while you are AFK."])
    Settings.CreateCheckbox(category, Proxy("autoInstance", Settings.VarType.Boolean, L["Pause In Instances"]),
        L["Hides your offer in dungeons, raids and battlegrounds."])
    local pins = Settings.CreateSliderOptions(5, 100, 5)
    pins:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
    Settings.CreateSlider(category, Proxy("pinCap", Settings.VarType.Number, L["Map Pins"]), pins, L["Most pins shown on a zone map."])
    -- How a request or clicker job announces itself; any mix, including none.
    Settings.CreateCheckbox(category, Proxy("orbShow", Settings.VarType.Boolean, L["Screen Button"], ns.UpdateOrb),
        L["A movable button that shows waiting requests and jobs."])
    local size = Settings.CreateSliderOptions(0.6, 2, 0.1)
    size:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value) return ("%d%%"):format(value * 100 + 0.5) end)
    Settings.CreateSlider(category, Proxy("orbScale", Settings.VarType.Number, L["Screen Button Size"], ns.UpdateOrb), size)
    Settings.CreateCheckbox(category, Proxy("autoOpen", Settings.VarType.Boolean, L["Open Requests Automatically"]),
        L["Opens the request window when a request or clicker job comes in."])
    Settings.CreateCheckbox(category, Proxy("watchOn", Settings.VarType.Boolean, L["Request Alerts"]),
        L["Alerts you when someone wants a summon near one of your warlocks or at a place you watch."])
    Settings.CreateCheckbox(category, Proxy("alertChat", Settings.VarType.Boolean, L["Chat Message"]))
    Settings.CreateCheckbox(category, Proxy("alertScreen", Settings.VarType.Boolean, L["Screen Message"]))
    Settings.CreateCheckbox(category, Proxy("sound", Settings.VarType.Boolean, L["Request Sound"]))
    local chat = L["In party or raid chat."]
    Settings.CreateCheckbox(category, Proxy("announceInvite", Settings.VarType.Boolean, L["Announce Invites"]), chat)
    Settings.CreateCheckbox(category, Proxy("announceTrade", Settings.VarType.Boolean, L["Announce Trades"]), chat)
    Settings.CreateCheckbox(category, Proxy("announceCast", Settings.VarType.Boolean, L["Announce Casts"]), chat)
    Settings.CreateCheckbox(category, Proxy("worldMap", Settings.VarType.Boolean, L["World Map Tab"]), L["Needs a reload."])
    Settings.CreateCheckbox(category, Proxy("minimapShow", Settings.VarType.Boolean, L["Minimap Button"], ns.UpdateMinimapButton))

    Settings.RegisterAddOnCategory(category)
    ns.OpenOptions = function()
        if InCombatLockdown() then return end
        Settings.OpenToCategory(category:GetID())
    end
end
