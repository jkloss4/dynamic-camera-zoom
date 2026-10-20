-- Dynamic Camera Zoom: zooms the camera and the minimap to set distances while something's going on - talking to an
-- NPC, using a mailbox or bank, riding a mount or a flight path, being indoors or in a dungeon, fishing, fighting - and
-- back to where they were when it ends. Each trigger has its own settings.
--
-- The game lets addons zoom the camera only by an amount (CameraZoomIn/Out), at the speed of the cameraZoomSpeed
-- setting. So a zoom works out the distance to go and sets that speed for the transition time asked, then puts the
-- player's own speed back. Minimap zoom is a level (0 farthest out); a transition steps through the levels between.
--
-- Several triggers can be going on at once. The camera and the minimap are each zoomed by the highest-priority one
-- (Priority tab) that zooms them; when none does any more, they go back to where they were before the first one did.

local addonName, ns = ...

local IS_RETAIL = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE

local MAX_ZOOM_SPEED = 50 -- the game's limit for cameraZoomSpeed, in yards per second
local POLL_INTERVAL = 0.1 -- how often the triggers are checked

-- Every trigger, in the default priority order (highest first). Flying mounts are told apart from ground ones on
-- retail only: WoW: Forever has no flying mounts, and no flying trigger.
local ALL_TRIGGERS = { "combat", "fishing", "npc", "services", "taxi", "flying", "ground", "instance", "indoors" }
local TRIGGERS = {}
for _, id in ipairs(ALL_TRIGGERS) do
    if id ~= "flying" or IS_RETAIL then TRIGGERS[#TRIGGERS + 1] = id end
end

local TRIGGER_NAMES = {
    combat = "Combat",
    fishing = "Fishing",
    npc = "Talking to NPCs",
    services = "Mailbox, Bank & Auction House",
    taxi = "Flight Paths",
    flying = "Flying Mounts",
    ground = IS_RETAIL and "Ground Mounts" or "Mounts",
    instance = "Dungeons & Raids",
    indoors = "Indoors",
}

local TRIGGER_TEXT = {
    combat = "while you're in combat",
    fishing = "while you're fishing",
    npc = "while you talk to an NPC (a quest giver, vendor, trainer...)",
    services = "while a mailbox, bank, guild bank or auction house is open",
    taxi = "while you're on a flight path",
    flying = "while you're on a flying mount",
    ground = IS_RETAIL and "while you're on a ground mount" or "while you're mounted",
    instance = IS_RETAIL and "while you're in a dungeon, raid or delve" or "while you're in a dungeon or raid",
    indoors = "while you're indoors (in a building or cave)",
}

local function trigger(camera, distance, minimap, zoom, delay, transition)
    return { camera = camera, cameraDistance = distance, minimap = minimap, minimapZoom = zoom, startDelay = delay,
        startTransition = transition, restore = true, endDelay = 0, endTransition = transition }
end
local DEFAULTS = {
    combat = trigger(true, 25, false, 1, 0, 0.5),
    fishing = trigger(true, 5, false, 3, 0, 0.5),
    npc = trigger(true, 6, false, 3, 0, 0.5),
    services = trigger(true, 6, false, 3, 0, 0.5),
    taxi = trigger(true, 35, true, 0, 0.5, 1.5),
    flying = trigger(true, 30, true, 0, 0.5, 1),
    ground = trigger(true, 20, false, 1, 0, 1),
    instance = trigger(false, 15, false, 2, 0, 1),
    indoors = trigger(true, 10, false, 3, 0, 0.5),
}
DEFAULTS.fishing.endDelay = 3 -- between casts, so it doesn't zoom back out each time
local GENERAL_DEFAULTS = { respectManualZoom = true, waitOutCombat = true, minimapStep = 0.1 }

local db -- DynamicCameraZoomDB

---------------------------------------------------------------------------
-- Camera
---------------------------------------------------------------------------

--- The farthest the camera can go: 15 yards times the game's max zoom factor (Options > Camera's Max Camera Distance)
local function maxCameraDistance()
    local factor = tonumber(GetCVar("cameraDistanceMaxZoomFactor")) or 1.9
    return math.floor(15 * factor * 2 + 0.5) / 2
end

local cameraTarget, cameraUntil -- where a zoom of ours is headed, and when it gets there
local speedToken = 0
local zoomingCamera = false -- our own CameraZoomIn/Out calls, which aren't the player zooming

--- Where the camera is, or where a zoom of ours is still taking it (zooms are relative to where it's headed)
local function cameraDistance()
    if cameraTarget and GetTime() < cameraUntil then return cameraTarget end
    return GetCameraZoom()
end

local function restoreZoomSpeed()
    if db.userZoomSpeed then
        SetCVar("cameraZoomSpeed", db.userZoomSpeed)
        db.userZoomSpeed = nil
    end
end

local function zoomCamera(distance, transition)
    distance = math.max(0, math.min(distance, maxCameraDistance()))
    local change = distance - cameraDistance()
    if math.abs(change) < 0.05 then return end

    local speed = transition > 0 and math.min(MAX_ZOOM_SPEED, math.abs(change) / transition) or MAX_ZOOM_SPEED
    speed = math.max(speed, 1)
    -- Saved before the first change, so it's put back even if the game closes mid-zoom (ADDON_LOADED)
    if not db.userZoomSpeed then db.userZoomSpeed = GetCVar("cameraZoomSpeed") end
    SetCVar("cameraZoomSpeed", speed)
    zoomingCamera = true
    if change > 0 then CameraZoomOut(change) else CameraZoomIn(-change) end
    zoomingCamera = false

    local duration = math.abs(change) / speed
    cameraTarget, cameraUntil = distance, GetTime() + duration
    speedToken = speedToken + 1
    local token = speedToken
    C_Timer.After(duration + 0.2, function()
        if token == speedToken then restoreZoomSpeed() end
    end)
end

---------------------------------------------------------------------------
-- Minimap
---------------------------------------------------------------------------

local function minimapLevels()
    return Minimap and Minimap.GetZoomLevels and Minimap:GetZoomLevels() or 6
end

local minimapTicker
local zoomingMinimap = false -- our own SetZoom calls, which aren't the player zooming

local function setMinimapZoom(level)
    zoomingMinimap = true
    Minimap:SetZoom(level)
    zoomingMinimap = false
end

local function zoomMinimap(level, transition)
    if not Minimap then return end
    if minimapTicker then minimapTicker:Cancel(); minimapTicker = nil end
    level = math.max(0, math.min(level, minimapLevels() - 1))
    local steps = level - Minimap:GetZoom()
    if steps == 0 then return end
    if transition <= 0 or db.minimapStep <= 0 or math.abs(steps) == 1 then
        setMinimapZoom(level)
        return
    end
    -- One level at a time, spread over the transition but no slower than Minimap Zoom Step a level: the minimap has
    -- only a few levels, so spread over a long transition each step lagged. A step of 0 jumps straight there.
    local direction = steps > 0 and 1 or -1
    setMinimapZoom(Minimap:GetZoom() + direction)
    minimapTicker = C_Timer.NewTicker(math.min(db.minimapStep, transition / math.abs(steps)), function(ticker)
        local zoom = Minimap:GetZoom()
        if zoom == level then ticker:Cancel(); minimapTicker = nil return end
        setMinimapZoom(zoom + direction)
    end, math.abs(steps) - 1)
end

---------------------------------------------------------------------------
-- Which triggers are going on
---------------------------------------------------------------------------

-- Mount types (C_MountJournal's mountTypeID) that fly, skyriding included
local FLYING_MOUNT_TYPES = {
    [247] = true, [248] = true, [398] = true, [402] = true, [407] = true, [424] = true, [426] = true, [428] = true,
    [429] = true, [430] = true, [436] = true, [437] = true, [442] = true, [444] = true, [445] = true,
}

--- "flying" or "ground" for the mount the player is on. Only retail tells them apart (its mount journal knows which
--- one is out); everywhere else every mount is a ground mount.
local function mountKind()
    if not (IS_RETAIL and C_MountJournal and C_MountJournal.GetMountIDs) then return "ground" end
    for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
        local isActive = select(4, C_MountJournal.GetMountInfoByID(mountID))
        if isActive then
            local mountType = select(5, C_MountJournal.GetMountInfoExtraByID(mountID))
            return FLYING_MOUNT_TYPES[mountType] and "flying" or "ground"
        end
    end
    return "ground"
end

-- Fishing: the player is channeling or casting a spell with Fishing in its name - plain Fishing, and kinds like
-- Midnight's Void Hole Fishing. By name, as the spell IDs differ between clients, ranks and kinds.
local FISHING_NAME = (C_Spell and C_Spell.GetSpellName and (C_Spell.GetSpellName(131474) or C_Spell.GetSpellName(7620)))
    or (GetSpellInfo and GetSpellInfo(7620)) or "Fishing"

local function isFishingSpell(name)
    return type(name) == "string" and not (issecretvalue and issecretvalue(name))
        and name:find(FISHING_NAME, 1, true) ~= nil
end

-- It ends with the cast; its end Zoom Delay (default 3 sec) keeps it from zooming back out between casts
local function isFishing()
    local channelOk, channel = pcall(UnitChannelInfo, "player")
    local castOk, cast = pcall(UnitCastingInfo, "player")
    return (channelOk and isFishingSpell(channel)) or (castOk and isFishingSpell(cast)) or false
end

-- /dcz fishing: print what the player is channeling or casting, to see a fishing kind's spell name
local function printCasting()
    local _, channel = pcall(UnitChannelInfo, "player")
    local _, cast = pcall(UnitCastingInfo, "player")
    print(("Dynamic Camera Zoom: channeling %s, casting %s (fishing: %s)"):format(tostring(channel), tostring(cast),
        tostring(isFishingSpell(channel) or isFishingSpell(cast))))
end

-- Mailbox, bank, guild bank and auction house: open from their show event until their close event
local SERVICE_EVENTS = {
    MAIL_SHOW = "mail", MAIL_CLOSED = false,
    BANKFRAME_OPENED = "bank", BANKFRAME_CLOSED = false,
    GUILDBANKFRAME_OPENED = "guildbank", GUILDBANKFRAME_CLOSED = false,
    AUCTION_HOUSE_SHOW = "auction", AUCTION_HOUSE_CLOSED = false,
}
local SERVICE_OF = {
    MAIL_CLOSED = "mail", BANKFRAME_CLOSED = "bank", GUILDBANKFRAME_CLOSED = "guildbank",
    AUCTION_HOUSE_CLOSED = "auction",
}
local openServices = {}

local mounted -- "flying" or "ground" once mounted (found once, when you mount)

--- The triggers going on now, as a set
local function currentTriggers()
    local now = {}
    if UnitAffectingCombat("player") then now.combat = true end
    if isFishing() then now.fishing = true end
    if UnitExists("npc") then now.npc = true end
    if next(openServices) then now.services = true end
    if UnitOnTaxi("player") then now.taxi = true end
    if IsMounted() then
        mounted = mounted or mountKind()
        now[mounted] = true
    else
        mounted = nil
    end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
        now.instance = true
    end
    if IsIndoors() then now.indoors = true end
    return now
end

---------------------------------------------------------------------------
-- Zooming for the highest-priority trigger
---------------------------------------------------------------------------

local startedAt = {} -- trigger -> when it started (its delay counts from there)

-- The camera and the minimap are handled the same way, each on its own
local channels = {
    camera = {
        enabledKey = "camera",
        target = function(settings) return settings.cameraDistance end,
        current = function() return cameraDistance() end,
        zoom = function(value, transition) zoomCamera(value, transition) end,
    },
    minimap = {
        enabledKey = "minimap",
        target = function(settings) return settings.minimapZoom end,
        current = function() return Minimap and Minimap:GetZoom() end,
        zoom = function(value, transition) zoomMinimap(value, transition) end,
    },
}
-- Each channel's state: owner (the trigger zooming it), saved (where it was before the first trigger zoomed it),
-- manual (the player zoomed it themselves while a trigger had it)
for _, channel in pairs(channels) do channel.owner, channel.saved, channel.manual = nil, nil, false end

local function priorityOf(id)
    for index, other in ipairs(db.priority) do
        if other == id then return index end
    end
    return #db.priority + 1
end

--- The highest-priority trigger that's going on, past its delay, and zooms this channel
local function ownerFor(channel, now, inCombat)
    local best, bestPriority
    for id in pairs(now) do
        local settings = db[id]
        local waiting = db.waitOutCombat and inCombat and id ~= "combat"
        if settings[channel.enabledKey] and not waiting and GetTime() - startedAt[id] >= settings.startDelay then
            local priority = priorityOf(id)
            if not best or priority < bestPriority then
                best, bestPriority = id, priority
            end
        end
    end
    return best
end

local function updateChannel(channel, now, inCombat)
    local owner = ownerFor(channel, now, inCombat)
    if owner == channel.owner then return end
    local previous = channel.owner
    channel.owner = owner

    if owner then
        -- Remember where it was before the first trigger took it
        if not previous then
            channel.saved, channel.manual = channel.current(), false
        end
        -- Handing over from a trigger that ended goes at that one's end speed; otherwise at the new one's start speed
        local transition = (previous and not now[previous]) and db[previous].endTransition
            or db[owner].startTransition
        channel.zoom(channel.target(db[owner]), transition)
    elseif previous then
        -- None zooms it any more: back to where it was, if the last one restores and the player didn't zoom it
        local settings = db[previous]
        if settings.restore and channel.saved and not (db.respectManualZoom and channel.manual) then
            channel.zoom(channel.saved, settings.endTransition)
        end
        channel.saved = nil
    end
end

local endedAt = {} -- trigger -> when it stopped going on; it still counts until its end delay has passed

local function poll()
    local now = currentTriggers()
    local time = GetTime()
    for id in pairs(startedAt) do
        if now[id] then
            endedAt[id] = nil
        else
            endedAt[id] = endedAt[id] or time
            if time - endedAt[id] >= db[id].endDelay then
                startedAt[id], endedAt[id] = nil, nil
            else
                now[id] = true -- still in its end delay
            end
        end
    end
    for id in pairs(now) do
        startedAt[id] = startedAt[id] or time
    end
    local inCombat = now.combat
    updateChannel(channels.camera, now, inCombat)
    updateChannel(channels.minimap, now, inCombat)
end

-- The player zooming the camera (mouse wheel, keys) or minimap (its zoom buttons) themselves
hooksecurefunc("CameraZoomIn", function()
    if not zoomingCamera and channels.camera.owner then channels.camera.manual = true end
end)
hooksecurefunc("CameraZoomOut", function()
    if not zoomingCamera and channels.camera.owner then channels.camera.manual = true end
end)
if Minimap then
    hooksecurefunc(Minimap, "SetZoom", function()
        if not zoomingMinimap and channels.minimap.owner then channels.minimap.manual = true end
    end)
end

local poller = CreateFrame("Frame")
local sincePoll = 0
-- /dcz zoom and /dcz trace: the camera distance and minimap zoom, in the sliders' terms, to find values to set
local function minimapSliderText()
    if not Minimap then return "?" end
    local last = minimapLevels() - 1
    local value = last - Minimap:GetZoom() -- the slider runs Closest (0) to Farthest
    if value == 0 then return "Closest" elseif value == last then return "Farthest" end
    return tostring(value)
end

local function zoomText()
    return ("camera %.1f yd, minimap %s"):format(math.floor(GetCameraZoom() * 2 + 0.5) / 2, minimapSliderText())
end

local function printZoom()
    print("Dynamic Camera Zoom: " .. zoomText())
end

-- Trace: prints the zoom each time it settles (it's held for half a second) after a change
local TRACE_SETTLE = 0.5
local tracing = false
local lastTraced, pendingText, pendingSince

local function traceZoom()
    local text = zoomText()
    if text == lastTraced then
        pendingText = nil
        return
    end
    if text ~= pendingText then
        pendingText, pendingSince = text, GetTime()
    elseif GetTime() - pendingSince >= TRACE_SETTLE then
        print("Dynamic Camera Zoom: " .. text)
        lastTraced, pendingText = text, nil
    end
end

poller:SetScript("OnUpdate", function(_, elapsed)
    sincePoll = sincePoll + elapsed
    if sincePoll < POLL_INTERVAL then return end
    sincePoll = 0
    poll()
    if tracing then traceZoom() end
end)
poller:Hide() -- shown once the saved settings are loaded

---------------------------------------------------------------------------
-- Options page (Options > AddOns > Dynamic Camera Zoom), drawn in Blizzard's settings style by SettingsKit
---------------------------------------------------------------------------

local Kit = ns.SettingsKit

local function defaultPriority()
    return CopyTable(TRIGGERS)
end

local page = Kit.NewPage("Dynamic Camera Zoom", {
    onDefaults = function()
        for _, id in ipairs(TRIGGERS) do db[id] = CopyTable(DEFAULTS[id]) end
        for key, value in pairs(GENERAL_DEFAULTS) do db[key] = value end
        db.priority = defaultPriority()
    end,
})
local triggersTab, priorityTab = unpack(page:Tabs({ "Triggers", "Priority" }))

-- Triggers tab: the general options, then one trigger's settings at a time, picked from a dropdown
triggersTab:Header("General")
triggersTab:Checkbox("Respect Manual Zoom",
    function() return db and db.respectManualZoom end, function(value) db.respectManualZoom = value end,
    "If you zoom the camera or minimap yourself while a trigger has zoomed it, it isn't put back when the trigger "
        .. "ends.")
triggersTab:Checkbox("Wait Out Combat",
    function() return db and db.waitOutCombat end, function(value) db.waitOutCombat = value end,
    "Hold off other triggers' zooms until combat ends. The Combat trigger still zooms.")
triggersTab:Slider("Minimap Zoom Step", 0, 0.5, 0.05,
    function() return db and db.minimapStep end, function(value) db.minimapStep = value end,
    function(value) return value == 0 and "Instant" or ("%.2f sec"):format(value) end,
    "How long the minimap takes for each zoom level it passes through, at most (a short transition can make it "
        .. "quicker). Instant jumps straight to the level.")

local selected = TRIGGERS[1]
local function setting(key)
    return function() return db and db[selected][key] end, function(value) db[selected][key] = value end
end
local function onlyWith(key)
    return { indent = true, enabled = function() return db and db[selected][key] end }
end
local function seconds(value) return ("%.1f sec"):format(value) end

triggersTab:Header("Trigger Settings")
local triggerOptions = {}
for _, id in ipairs(TRIGGERS) do
    triggerOptions[#triggerOptions + 1] = { value = id, label = TRIGGER_NAMES[id], tooltip = "Zooms " .. TRIGGER_TEXT[id] .. "." }
end
triggersTab:Dropdown("Settings For", triggerOptions,
    function() return selected end,
    function(id) selected = id; page:Refresh() end,
    "Which trigger's settings to show below.")

triggersTab:Subheader("Zoom")
local getCamera, setCamera = setting("camera")
triggersTab:Checkbox("Zoom Camera", getCamera, setCamera,
    function() return "Zoom the camera to the distance below " .. TRIGGER_TEXT[selected] .. "." end)
local getDistance, setDistance = setting("cameraDistance")
triggersTab:Slider("Camera Distance", 1, maxCameraDistance(), 0.5, getDistance, setDistance,
    function(value) return ("%.1f yd"):format(value) end,
    "How far the camera zooms out. The most is your Max Camera Distance (Options > Camera), "
        .. ("%.1f yards now."):format(maxCameraDistance()), onlyWith("camera"))

local getMinimap, setMinimap = setting("minimap")
triggersTab:Checkbox("Zoom Minimap", getMinimap, setMinimap,
    function() return "Zoom the minimap to the level below " .. TRIGGER_TEXT[selected] .. "." end)
-- Closest on the left, Farthest on the right: the slider runs the other way to the game's zoom levels (0 is the
-- farthest out), so it shows the last level minus the saved one
local lastLevel = minimapLevels() - 1
triggersTab:Slider("Minimap Zoom", 0, lastLevel, 1,
    function() return db and lastLevel - db[selected].minimapZoom end,
    function(value) db[selected].minimapZoom = lastLevel - value end,
    function(value)
        if value == 0 then return "Closest" elseif value == lastLevel then return "Farthest" end
        return tostring(value)
    end,
    "How far the minimap zooms, from Closest to Farthest (the most map).", onlyWith("minimap"))

triggersTab:Subheader("When It Starts")
local getStartDelay, setStartDelay = setting("startDelay")
triggersTab:Slider("Zoom Delay", 0, 5, 0.1, getStartDelay, setStartDelay, seconds,
    "How long to wait after it starts before zooming.")
local getStartTransition, setStartTransition = setting("startTransition")
triggersTab:Slider("Transition Time", 0, 3, 0.1, getStartTransition, setStartTransition, seconds,
    "How long the zoom takes. 0 is as fast as the game allows.")

triggersTab:Subheader("When It Ends")
local getRestore, setRestore = setting("restore")
triggersTab:Checkbox("Restore Previous Zoom", getRestore, setRestore,
    "When it ends (and no other trigger zooms instead), put the camera and minimap back where they were.")
local getEndDelay, setEndDelay = setting("endDelay")
triggersTab:Slider("Zoom Delay", 0, 5, 0.1, getEndDelay, setEndDelay, seconds,
    "How long to hold the zoom after it ends before zooming back (or to the next trigger's zoom).")
local getEndTransition, setEndTransition = setting("endTransition")
triggersTab:Slider("Transition Time", 0, 3, 0.1, getEndTransition, setEndTransition, seconds,
    "How long zooming back takes. 0 is as fast as the game allows.")

-- Priority tab: one row per place, with up/down arrows (the minimal scroll bar's stepper art), as in Clean Bags
priorityTab:Header("Priority")
priorityTab:Text("When several triggers are going on, the highest one that zooms the camera (or minimap) zooms it.")
priorityTab:Spacer(22)

local function move(index, delta)
    local order = db.priority
    local target = index + delta
    if target < 1 or target > #order then return end
    order[index], order[target] = order[target], order[index]
    PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
    page:Refresh()
end

local function arrow(row, atlas, onClick)
    local button = CreateFrame("Button", nil, row)
    button:SetSize(17, 11)
    button:SetNormalAtlas(atlas)
    button:SetPushedAtlas(atlas .. "-down")
    button:SetDisabledAtlas(atlas)
    button:GetDisabledTexture():SetAlpha(0.3)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        self:SetNormalAtlas(atlas .. "-over")
        row:ShowHover(self)
    end)
    button:SetScript("OnLeave", function(self)
        self:SetNormalAtlas(atlas)
        row:HideHover()
    end)
    return button
end

for index = 1, #TRIGGERS do
    local row = priorityTab:SettingRow(tostring(index))
    -- The trigger in this row changes as they're moved, so its tooltip is looked up when shown
    function row:ShowHover(owner)
        local id = db.priority[index]
        self.HoverBackground:Show()
        SettingsTooltip:SetOwner(owner or self.Hover, "ANCHOR_RIGHT", -10, 0)
        GameTooltip_AddHighlightLine(SettingsTooltip, TRIGGER_NAMES[id])
        GameTooltip_AddNormalLine(SettingsTooltip, "Zooms " .. TRIGGER_TEXT[id] .. ".", true)
        GameTooltip_AddBlankLineToTooltip(SettingsTooltip)
        GameTooltip_AddInstructionLine(SettingsTooltip, "Use the arrows to move it up (higher priority) or down.", true)
        SettingsTooltip:Show()
    end
    local up = arrow(row, "minimal-scrollbar-arrow-top", function() move(index, -1) end)
    up:SetPoint("LEFT", row, "CENTER", -80, 0)
    local down = arrow(row, "minimal-scrollbar-arrow-bottom", function() move(index, 1) end)
    down:SetPoint("LEFT", up, "RIGHT", 6, 0)
    priorityTab:OnRefresh(function()
        if not db then return end
        row.Text:SetText(("%d. %s"):format(index, TRIGGER_NAMES[db.priority[index]]))
        up:SetEnabled(index > 1)
        down:SetEnabled(index < #db.priority)
    end)
end

Kit.Register(page)

SLASH_DYNAMICCAMERAZOOM1 = "/dynamiccamerazoom"
SLASH_DYNAMICCAMERAZOOM2 = "/dcz"
SlashCmdList["DYNAMICCAMERAZOOM"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "zoom" then
        printZoom()
    elseif msg == "trace" then
        tracing = not tracing
        lastTraced, pendingText = tracing and zoomText() or nil, nil
        print("Dynamic Camera Zoom: trace " .. (tracing and ("on - " .. zoomText()) or "off") .. ".")
    elseif msg == "fishing" then
        printCasting()
    else
        Kit.Open(page)
    end
end

---------------------------------------------------------------------------
-- Loading and events
---------------------------------------------------------------------------

--- A saved priority order with every trigger of this client in it once (triggers added later go in where the default
--- order has them; ones this client doesn't have, like flying on WoW: Forever, are left out)
local function fixPriority(order)
    local result, seen = {}, {}
    for _, id in ipairs(order or {}) do
        if DEFAULTS[id] and not seen[id] and tContains(TRIGGERS, id) then
            result[#result + 1], seen[id] = id, true
        end
    end
    for defaultIndex, id in ipairs(TRIGGERS) do
        if not seen[id] then
            table.insert(result, math.min(defaultIndex, #result + 1), id)
            seen[id] = true
        end
    end
    return result
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
for event in pairs(SERVICE_EVENTS) do
    pcall(events.RegisterEvent, events, event) -- not every event exists on every client
end
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        DynamicCameraZoomDB = DynamicCameraZoomDB or {}
        db = DynamicCameraZoomDB
        for _, id in ipairs(ALL_TRIGGERS) do
            db[id] = db[id] or {}
            -- One delay and transition for both ends, from before they were split
            if db[id].delay ~= nil then
                db[id].startDelay, db[id].startTransition = db[id].delay, db[id].transition
                db[id].endTransition, db[id].delay, db[id].transition = db[id].transition, nil, nil
            end
            for key, value in pairs(DEFAULTS[id]) do
                if db[id][key] == nil then db[id][key] = value end
            end
        end
        for key, value in pairs(GENERAL_DEFAULTS) do
            if db[key] == nil then db[key] = value end
        end
        db.priority = fixPriority(db.priority)
        -- The game closed or reloaded mid-zoom: put the player's own zoom speed back
        restoreZoomSpeed()
        page:Refresh()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Start fresh after a loading screen
        wipe(openServices)
        wipe(startedAt)
        wipe(endedAt)
        mounted = nil
        for _, channel in pairs(channels) do channel.owner, channel.saved, channel.manual = nil, nil, false end
        poller:Show()
    elseif SERVICE_EVENTS[event] then
        openServices[SERVICE_EVENTS[event]] = true
    elseif SERVICE_OF[event] then
        openServices[SERVICE_OF[event]] = nil
    end
end)
