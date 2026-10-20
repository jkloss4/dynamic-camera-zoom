-- SettingsKit: option pages in Options > AddOns that look like Blizzard's own (Controls, Keybindings, Graphics...).
--
-- The same file ships in every addon of Jay's (Bubble Font Size, Nameplate Quest Markers, Compass, Tooltip Anchors,
-- Quick Emote, Clean Bags, Toast Banners):
-- change it in one place and copy it to the others. Measurements and templates come from Blizzard's settings code
-- (Blizzard_SettingsList, Blizzard_SettingControls, Graphics.xml).
--
-- Pages are canvas categories built entirely from the addon's own frames. Blizzard's own setting controls are pooled
-- frames shared with Blizzard's pages; running addon code inside them taints Blizzard's settings, so they're never
-- used here. Templates are only used for their art (checkbox, slider, dropdown with steppers, color swatch, tabs).
--
-- Usage:
--   local Kit = ns.SettingsKit
--   local page = Kit.NewPage("My Addon", { onDefaults = function() ... end })
--   page:Header("General")
--   page:Checkbox("Enabled", get, set, "Tooltip text", { enabled = function() return ... end, indent = true })
--   page:Slider("Size", 8, 32, 1, get, set, function(v) return v .. " pt" end, "Tooltip")
--   page:Dropdown("Style", { { label = "A", value = "a", tooltip = "..." }, ... }, get, set, "Tooltip")
--   page:CheckboxDropdown("Show", get, set, options, getOption, setOption, "Tooltip")  -- dropdown beside a checkbox
--   page:ColorSwatch("Color", getRGBA, setRGBA, "Tooltip", { hasOpacity = true })
--   page:CheckboxColorSwatch("Custom Color", get, set, getRGBA, setRGBA, "Tooltip")  -- swatch beside a checkbox
--   page:Button("Do Something", onClick, "Tooltip")
--   page:Expandable("Section", { key = "section", expanded = true }) ... page:EndExpandable()
--   local general, colors = unpack(page:Tabs({ "General", "Colors" }))  -- Graphics-style tabbed pane; each tab is a
--                                                                       -- list with the same methods as the page
--   Kit.Register(page)                -- or Kit.Register(page, parentCategory) for a subcategory
--   Kit.Open(page)

local _, ns = ...
local Kit = {}
ns.SettingsKit = Kit

-- Blizzard's settings list metrics
local LIST_TOP = -52       -- the list starts below the 50px header (title, divider, Defaults button)
local LIST_PAD_TOP = 10    -- list padding above the first row
local ROW_X = 10           -- rows start 25px into a list that sits 15px left of the header
local SPACING = 9          -- between rows
local ROW_H = 26           -- setting rows
local HEADER_H = 45        -- section headers
local EXPAND_H = 30        -- collapsible section bars
local LABEL_X = 37         -- label inset within a row
local INDENT = 15          -- per indent level
local CONTROL_X = -80      -- controls start this far from a row's center
local SCROLLBAR_W = 20     -- space kept right of the list for the scroll bar

local Tooltip = SettingsTooltip or GameTooltip

-- errorText: a red line after the text, e.g. why a setting is disabled
local function ShowTooltip(owner, title, text, errorText)
    if not (title or text) then return end
    Tooltip:SetOwner(owner, "ANCHOR_RIGHT", -10, 0)
    if title then GameTooltip_AddHighlightLine(Tooltip, title) end
    if text then GameTooltip_AddNormalLine(Tooltip, text, true) end
    if errorText then
        GameTooltip_AddBlankLineToTooltip(Tooltip)
        GameTooltip_AddErrorLine(Tooltip, errorText, true)
    end
    Tooltip:Show()
end

local function HideTooltip()
    Tooltip:Hide()
end

local function Evaluate(value)
    if type(value) == "function" then return value() end
    return value
end

---------------------------------------------------------------------------
-- List: a scrollable column of rows. A page is a list; so is each tab of a tabbed pane.
---------------------------------------------------------------------------
local List = {}
List.__index = List

local function NewList(page, parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    -- Blizzard's settings scroll bar: hidden while there's nothing to scroll
    scroll.ScrollBar:ClearAllPoints()
    scroll.ScrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 0, -4)
    scroll.ScrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", -1, 7)
    scroll.ScrollBar:SetHideIfUnscrollable(true)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, width) content:SetWidth(width) end)

    return setmetatable({ page = page, scroll = scroll, content = content, rows = {}, refreshers = {}, pool = {} }, List)
end

-- Stack the rows that aren't inside a collapsed section
function List:Layout()
    local y = -LIST_PAD_TOP
    for _, row in ipairs(self.rows) do
        local shown = not (row.section and not row.section.expanded) and not row.hidden
        row:SetShown(shown)
        if shown then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.content, "TOPLEFT", ROW_X, y)
            row:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, y)
            y = y - row:GetHeight() - SPACING
        end
    end
    self.content:SetHeight(-y + LIST_PAD_TOP)
end

function List:NewRow(height)
    local row = CreateFrame("Frame", nil, self.content)
    row:SetHeight(height)
    row.section = self.section
    self.rows[#self.rows + 1] = row
    return row
end

function List:OnRefresh(fn)
    self.refreshers[#self.refreshers + 1] = fn
end

-- Remove every row (and its refresh function), to rebuild the list. WoW never frees frames, so rows of a kind that
-- can be reused (see SettingRow) are kept in the list's pool and taken again by the rebuild instead of new frames.
function List:Clear()
    for _, row in ipairs(self.rows) do
        row:Hide()
        if row.kind then
            self.pool[row.kind] = self.pool[row.kind] or {}
            table.insert(self.pool[row.kind], row)
        end
    end
    wipe(self.rows)
    wipe(self.refreshers)
    self.section = nil
end

-- A setting row: gold label on the left (gray while disabled), hover highlight and tooltip like Blizzard's rows.
-- opts.indent: true or a number of levels. opts.enabled: function (or value) deciding whether it can be changed.
-- opts.disabledTooltip: text (or function) shown in red while it's disabled, saying why. tooltip can be a function.
-- kind (optional): the control's name; a cleared row of that kind is reused. Returns the row and whether it was reused
-- (its control already exists then, and only needs its new settings).
function List:SettingRow(label, tooltip, opts, kind)
    opts = opts or {}
    local pool = kind and self.pool[kind]
    local row = pool and table.remove(pool)
    local reused = row ~= nil

    if reused then
        row.section, row.hidden = self.section, nil
        self.rows[#self.rows + 1] = row
    else
        row = self:NewRow(ROW_H)
        row.kind = kind

        row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.Text:SetJustifyH("LEFT")
        row.Text:SetWordWrap(false)

        row.HoverBackground = row:CreateTexture(nil, "BACKGROUND")
        row.HoverBackground:SetPoint("TOPLEFT", -10, 0)
        row.HoverBackground:SetPoint("BOTTOMRIGHT", -5, 0)
        row.HoverBackground:SetColorTexture(1, 1, 1, 0.1)

        -- the label half of the row shows the tooltip (and clicks a checkbox, like Blizzard's)
        row.Hover = CreateFrame("Frame", nil, row)
        row.Hover:SetPoint("TOPLEFT")
        row.Hover:SetPoint("BOTTOMRIGHT", row, "BOTTOM", -80, 0)
        function row:ShowHover(owner)
            self.HoverBackground:Show()
            local o = self.opts
            local reason = o.disabledTooltip and not self.IsEnabledSetting() and Evaluate(o.disabledTooltip) or nil
            ShowTooltip(owner or self.Hover, self.label, Evaluate(self.tooltip), reason)
        end
        function row:HideHover()
            self.HoverBackground:Hide()
            HideTooltip()
        end
        row.Hover:SetScript("OnEnter", function() row:ShowHover() end)
        row.Hover:SetScript("OnLeave", function() row:HideHover() end)

        row.IsEnabledSetting = function() return row.opts.enabled == nil or Evaluate(row.opts.enabled) end
        function row:UpdateEnabled()
            local enabled = self.IsEnabledSetting()
            self.Text:SetTextColor((enabled and NORMAL_FONT_COLOR or GRAY_FONT_COLOR):GetRGB())
            return enabled
        end
    end

    -- this row's settings (a reused row gets new ones)
    row.label, row.tooltip, row.opts = label, tooltip, opts
    local indent = (opts.indent == true and 1 or opts.indent or 0) * INDENT
    row.Text:SetFontObject(indent > 0 and "GameFontNormalSmall" or "GameFontNormal")
    row.Text:ClearAllPoints()
    row.Text:SetPoint("LEFT", LABEL_X + indent, 0)
    row.Text:SetPoint("RIGHT", row, "CENTER", -85, 0)
    row.Text:SetText(label)
    row.HoverBackground:Hide()
    return row, reused
end

-- Forward a control's hover to its row's highlight and tooltip
local function HookHover(row, control)
    control:HookScript("OnEnter", function(self) row:ShowHover(self) end)
    control:HookScript("OnLeave", function() row:HideHover() end)
end

function List:Checkbox(label, get, set, tooltip, opts)
    local row, reused = self:SettingRow(label, tooltip, opts, "Checkbox")
    row.get, row.set = get, set
    if not reused then
        local checkbox = CreateFrame("CheckButton", nil, row, "SettingsCheckboxTemplate")
        checkbox:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
        checkbox:SetScript("OnEnter", function(self) row:ShowHover(self) end)
        checkbox:SetScript("OnLeave", function() row:HideHover() end)
        checkbox:SetScript("OnClick", function(self)
            PlaySound(self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            row.set(self:GetChecked() and true or false)
            row.list.page:Refresh()
        end)
        row.Hover:SetScript("OnMouseUp", function() if checkbox:IsEnabled() then checkbox:Click() end end)
        row.Checkbox = checkbox
    end
    row.list = self

    local checkbox = row.Checkbox
    self:OnRefresh(function()
        checkbox:SetChecked(row.get() and true or false)
        checkbox:SetEnabled(row:UpdateEnabled())
    end)
    return row
end

-- A checkbox with a dropdown beside it, like Blizzard's checkbox-and-dropdown rows: the dropdown is only enabled while
-- the box is checked. options as in Dropdown. opts.dropdownTooltip: shown over the dropdown.
function List:CheckboxDropdown(label, get, set, options, getOption, setOption, tooltip, opts)
    opts = opts or {}
    local row = self:Checkbox(label, get, set, tooltip, opts)
    row.kind = nil -- has a control of its own beside the checkbox: never reused as a plain checkbox
    local control = CreateFrame("Frame", nil, row, "SettingsDropdownWithButtonsTemplate")
    control:SetPoint("LEFT", row.Checkbox, "RIGHT", 32, 0)
    control.Dropdown:SetWidth(220)
    control.Dropdown:HookScript("OnEnter", function(dropdown)
        row.HoverBackground:Show()
        ShowTooltip(dropdown, label, Evaluate(opts.dropdownTooltip or tooltip))
    end)
    control.Dropdown:HookScript("OnLeave", function() row:HideHover() end)

    local function Generate(_, root)
        for _, option in ipairs(Evaluate(options)) do
            local radio = root:CreateRadio(option.label,
                function() return getOption() == option.value end,
                function()
                    setOption(option.value)
                    self.page:Refresh()
                end)
            if option.tooltip then
                radio:SetTooltip(function(tip)
                    GameTooltip_SetTitle(tip, option.label)
                    GameTooltip_AddNormalLine(tip, option.tooltip)
                end)
            end
        end
    end

    -- set up the first time the page is shown, like Dropdown (the checkbox's refresh runs first)
    local isSetUp = false
    self:OnRefresh(function()
        if isSetUp then
            control.Dropdown:GenerateMenu()
        else
            control.Dropdown:SetupMenu(Generate)
            isSetUp = true
        end
        control:SetEnabled(row.Checkbox:IsEnabled() and row.Checkbox:GetChecked())
    end)
    row.Control = control
    return row
end

-- format(value) -> text shown right of the slider
function List:Slider(label, minValue, maxValue, step, get, set, format, tooltip, opts)
    local row = self:SettingRow(label, tooltip, opts)
    local slider = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate")
    slider:SetWidth(250)
    slider:SetPoint("LEFT", row, "CENTER", CONTROL_X, 3)
    HookHover(row, slider.Slider)

    format = format or function(v) return tostring(v) end
    local formatters = { [MinimalSliderWithSteppersMixin.Label.Right] = function(v)
        return format(math.floor(v / step + 0.5) * step)
    end }
    -- the template's value-changed callback also fires when the value is set from code; `syncing` marks those
    local syncing = false
    -- the value is filled in on refresh: saved settings may not be loaded while the page is built
    slider:Init(minValue, minValue, maxValue, math.floor((maxValue - minValue) / step + 0.5), formatters)
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if not syncing then
            set(math.floor(value / step + 0.5) * step)
            self.page:Refresh()
        end
    end, slider)

    self:OnRefresh(function()
        syncing = true
        slider:SetValue(get() or minValue)
        syncing = false
        slider:SetEnabled(row:UpdateEnabled())
    end)
    row.Slider = slider
    return row
end

-- options: list of { label = text, value = any, tooltip = text (optional) }; opts.steppers = false hides the arrows
function List:Dropdown(label, options, get, set, tooltip, opts)
    opts = opts or {}
    local row = self:SettingRow(label, tooltip, opts)
    local control = CreateFrame("Frame", nil, row, "SettingsDropdownWithButtonsTemplate")
    control:SetPoint("LEFT", row, "CENTER", -48, 3)
    control.Dropdown:SetWidth(220)
    HookHover(row, control.Dropdown)

    local function Generate(_, root)
        for _, option in ipairs(Evaluate(options)) do
            local radio = root:CreateRadio(option.label,
                function() return get() == option.value end,
                function()
                    set(option.value)
                    self.page:Refresh()
                end)
            if option.tooltip then
                radio:SetTooltip(function(tip)
                    GameTooltip_SetTitle(tip, option.label)
                    GameTooltip_AddNormalLine(tip, option.tooltip)
                end)
            end
        end
    end
    if opts.steppers == false then control:HideSteppers() end

    -- SetupMenu builds the menu right away, reading the options and values; saved settings may not be loaded while
    -- the page is built, so the menu is set up the first time the page is shown
    local isSetUp = false
    self:OnRefresh(function()
        if isSetUp then
            control.Dropdown:GenerateMenu()
        else
            control.Dropdown:SetupMenu(Generate)
            isSetUp = true
        end
        control:SetEnabled(row:UpdateEnabled())
    end)
    row.Control = control
    return row
end

-- A color swatch on a row that opens Blizzard's color picker
local function CreateSwatch(list, row, get, set, opts)
    local swatch = CreateFrame("Button", nil, row, "SettingsColorSwatchTemplate")
    swatch:SetScript("OnEnter", function(self) row:ShowHover(self) end)
    swatch:SetScript("OnLeave", function() row:HideHover() end)
    swatch:SetScript("OnClick", function()
        local r, g, b, a = get()
        local function Changed()
            local newR, newG, newB = ColorPickerFrame:GetColorRGB()
            set(newR, newG, newB, opts.hasOpacity and ColorPickerFrame:GetColorAlpha() or a)
            list.page:Refresh()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r, g = g, b = b, opacity = a, hasOpacity = opts.hasOpacity,
            swatchFunc = Changed, opacityFunc = Changed,
            cancelFunc = function() set(r, g, b, a); list.page:Refresh() end,
        })
    end)
    row.Swatch = swatch
    return swatch
end

-- get() -> r, g, b[, a]; set(r, g, b[, a]). opts.hasOpacity adds the picker's opacity slider.
function List:ColorSwatch(label, get, set, tooltip, opts)
    opts = opts or {}
    local row = self:SettingRow(label, tooltip, opts)
    local swatch = CreateSwatch(self, row, get, set, opts)
    swatch:SetPoint("LEFT", row, "CENTER", -73, 0)

    self:OnRefresh(function()
        local r, g, b = get()
        swatch:SetColorValue(CreateColor(r, g, b))
        swatch:SetEnabled(row:UpdateEnabled())
    end)
    return row
end

-- A checkbox with a color swatch beside it, like Blizzard's checkbox-and-swatch rows: the swatch is only enabled while
-- the box is checked. getColor/setColor as in ColorSwatch.
function List:CheckboxColorSwatch(label, get, set, getColor, setColor, tooltip, opts)
    opts = opts or {}
    local row = self:Checkbox(label, get, set, tooltip, opts)
    row.kind = nil -- has a control of its own beside the checkbox: never reused as a plain checkbox
    local swatch = CreateSwatch(self, row, getColor, setColor, opts)
    swatch:SetPoint("LEFT", row.Checkbox, "RIGHT", 12, 0)

    -- the checkbox's refresh runs first
    self:OnRefresh(function()
        local r, g, b = getColor()
        swatch:SetColorValue(CreateColor(r, g, b))
        swatch:SetEnabled(row.Checkbox:IsEnabled() and row.Checkbox:GetChecked())
    end)
    return row
end

-- A button on its own row at the label column, like Keybindings' "Quick Keybind Mode"
function List:Button(text, onClick, tooltip, opts)
    opts = opts or {}
    local row = self:NewRow(ROW_H)
    local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    button:SetSize(opts.width or 200, ROW_H)
    button:SetPoint("LEFT", LABEL_X - 2 + (opts.indent and INDENT or 0), 0)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
        self.page:Refresh()
    end)
    button:SetScript("OnEnter", function(b) ShowTooltip(b, text, tooltip) end)
    button:SetScript("OnLeave", HideTooltip)
    if opts.enabled ~= nil then
        self:OnRefresh(function() button:SetEnabled(Evaluate(opts.enabled)) end)
    end
    row.Button = button
    return row
end

-- A setting row with a button as its control
function List:ButtonRow(label, text, onClick, tooltip, opts)
    local row = self:SettingRow(label, tooltip, opts)
    local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    button:SetSize(200, ROW_H)
    button:SetPoint("LEFT", row, "CENTER", -40, 0)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
        self.page:Refresh()
    end)
    HookHover(row, button)
    self:OnRefresh(function() button:SetEnabled(row:UpdateEnabled()) end)
    row.Button = button
    return row
end

-- Section header: large white text, like "Mouse" on the Controls page
function List:Header(text, opts)
    opts = opts or {}
    self.section = nil -- headers end a collapsible section
    local row = self:NewRow(HEADER_H)
    local title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetJustifyH("LEFT")
    title:SetPoint("TOPLEFT", 7, -16)
    title:SetText(text)
    if opts.enabled ~= nil then
        self:OnRefresh(function()
            title:SetTextColor((Evaluate(opts.enabled) and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR):GetRGB())
        end)
    end
    return row
end

-- Smaller label inside a section (e.g. "In Combat"), white like Blizzard's sub-labels
function List:Subheader(text)
    local row = self:NewRow(18)
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", LABEL_X - 15, 0)
    label:SetText(text)
    return row
end

-- A line of plain text (description or note)
function List:Text(text, font)
    local row = self:NewRow(1)
    local label = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    label:SetPoint("TOPLEFT", LABEL_X - 15, 0)
    label:SetPoint("RIGHT", -20, 0)
    label:SetJustifyH("LEFT")
    label:SetSpacing(2)
    local function Update()
        label:SetText(Evaluate(text))
        row:SetHeight(math.max(14, label:GetStringHeight()))
    end
    if type(text) == "function" then
        -- filled in when the page is shown: saved settings may not be loaded while the page is built
        self:OnRefresh(function() Update(); self:Layout() end)
    else
        Update()
    end
    return row
end

-- Blizzard's header divider, for separating groups of rows
function List:Divider()
    local row = self:NewRow(8)
    local line = row:CreateTexture(nil, "ARTWORK")
    line:SetAtlas("Options_HorizontalDivider", true)
    line:SetPoint("LEFT", LABEL_X - 22, 0)
    line:SetPoint("RIGHT", -20, 0)
    return row
end

-- A collapsible section bar, like Keybindings' "Movement Keys". Rows added after it belong to it until the next
-- Header, Expandable or EndExpandable. opts.key remembers the state in Kit.collapsed (set by the addon to a saved
-- table to persist it); opts.expanded is the default.
function List:Expandable(text, opts)
    opts = opts or {}
    local row = self:NewRow(EXPAND_H)
    row.section = nil

    local state = Kit.collapsed or {}
    local section = { expanded = opts.expanded ~= false }
    if opts.key and state[opts.key] ~= nil then section.expanded = not state[opts.key] end
    self.section = section

    local button = CreateFrame("Button", nil, row)
    button:SetHeight(EXPAND_H)
    button:SetPoint("TOPLEFT")
    button:SetPoint("TOPRIGHT", -20, 0)
    local left = button:CreateTexture(nil, "BACKGROUND")
    left:SetAtlas("Options_ListExpand_Left", true)
    left:SetPoint("TOPLEFT")
    local right = button:CreateTexture(nil, "BACKGROUND")
    right:SetPoint("TOPRIGHT")
    local middle = button:CreateTexture(nil, "BACKGROUND")
    middle:SetAtlas("_Options_ListExpand_Middle", true)
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
    middle:SetPoint("TOPRIGHT", right, "TOPLEFT")
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 21, 2)
    label:SetText(text)

    local function Update()
        right:SetAtlas(section.expanded and "Options_ListExpand_Right_Expanded" or "Options_ListExpand_Right", true)
    end
    Update()

    button:SetScript("OnClick", function()
        section.expanded = not section.expanded
        if opts.key then
            Kit.collapsed = Kit.collapsed or {}
            Kit.collapsed[opts.key] = not section.expanded or nil
            if Kit.onCollapsedChanged then Kit.onCollapsedChanged(Kit.collapsed) end
        end
        Update()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        self:Layout()
    end)
    button:SetScript("OnEnter", function(b)
        label:SetFontObject("GameFontHighlight")
        if opts.tooltip then ShowTooltip(b, text, opts.tooltip) end
    end)
    button:SetScript("OnLeave", function()
        label:SetFontObject("GameFontNormal")
        HideTooltip()
    end)
    if opts.enabled ~= nil then
        self:OnRefresh(function()
            label:SetTextColor(((Evaluate(opts.enabled) and NORMAL_FONT_COLOR) or GRAY_FONT_COLOR):GetRGB())
        end)
    end
    return row
end

function List:EndExpandable()
    self.section = nil
end

function List:Spacer(height)
    return self:NewRow(math.max(1, (height or SPACING) - SPACING))
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
local Page = setmetatable({}, { __index = List })
Page.__index = Page

local defaultsDialogs = 0

-- opts.onDefaults: shows a Defaults button (with Blizzard's confirmation) that calls it
function Kit.NewPage(title, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame")
    -- start hidden, so the Settings panel showing it fires OnShow (which fills in the current values)
    frame:Hide()

    local page = { frame = frame, title = title, lists = {} }

    local header = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    header:SetJustifyH("LEFT")
    header:SetPoint("TOPLEFT", 7, -22)
    header:SetText(title)
    page.Title = header

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("Options_HorizontalDivider", true)
    divider:SetPoint("TOP", 0, -50)

    if opts.onDefaults then
        defaultsDialogs = defaultsDialogs + 1
        local dialogName = "SETTINGSKIT_DEFAULTS_" .. tostring(title):gsub("%W", "") .. defaultsDialogs
        StaticPopupDialogs[dialogName] = {
            text = SETTINGS_CONFIRM_DEFAULTS and SETTINGS_CONFIRM_DEFAULTS:format(title) or ("Reset " .. title .. " to its defaults?"),
            button1 = OKAY or ACCEPT, button2 = CANCEL,
            OnAccept = function() opts.onDefaults(); Kit.Refresh(page) end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        local defaults = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        defaults:SetSize(96, 22)
        defaults:SetPoint("TOPRIGHT", -36, -16)
        defaults:SetText(SETTINGS_DEFAULTS or DEFAULTS or "Defaults")
        defaults:SetScript("OnClick", function() StaticPopup_Show(dialogName) end)
        page.DefaultsButton = defaults
    end

    -- the page's own list fills the area below the header
    local list = NewList(page, frame)
    list.scroll:SetPoint("TOPLEFT", 0, LIST_TOP)
    list.scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_W, 2)
    for k, v in pairs(list) do page[k] = v end
    page.lists[1] = page

    setmetatable(page, Page)

    frame:SetScript("OnShow", function() Kit.Refresh(page) end)
    -- Blizzard calls these on canvas pages
    frame.OnRefresh = function() Kit.Refresh(page) end
    frame.OnCommit = function() end
    frame.OnDefault = function() end
    return page
end

function Page:Refresh()
    for _, list in ipairs(self.lists) do
        for _, fn in ipairs(list.refreshers) do fn() end
    end
end

function Page:Layout()
    for _, list in ipairs(self.lists) do List.Layout(list) end
end

-- Graphics-style tabbed pane filling the rest of the page: the page's own list is hidden and each tab gets its own.
-- names: tab labels. opts.title: text left of the tabs. opts.shared: one list for all tabs (tabs only call
-- opts.onSelect(index)), for pages where the tabs switch what the same controls edit. opts.above: height of a strip
-- above the tabs that keeps the page's own list, for rows shown on every tab (added to the page itself).
function Page:Tabs(names, opts)
    opts = opts or {}
    local above = opts.above or 0
    if above > 0 then
        self.scroll:ClearAllPoints()
        self.scroll:SetPoint("TOPLEFT", 0, LIST_TOP)
        self.scroll:SetPoint("TOPRIGHT", -SCROLLBAR_W, LIST_TOP)
        self.scroll:SetHeight(above)
        -- the strip never scrolls: its list padding can make it a few pixels taller than the strip
        self.scroll:EnableMouseWheel(false)
        self.scroll.ScrollBar:Hide()
        self.scroll.ScrollBar:HookScript("OnShow", self.scroll.ScrollBar.Hide)
    else
        self.scroll:Hide()
    end

    local section = CreateFrame("Frame", nil, self.frame)
    section:SetPoint("TOPLEFT", 22, LIST_TOP - 18 - above)
    section:SetPoint("BOTTOMRIGHT", -30, 22) -- leaves room right of the pane for the scroll bar

    if opts.title then
        local title = section:CreateFontString(nil, "BACKGROUND", "GameFontHighlightLarge")
        title:SetPoint("TOPLEFT")
        title:SetText(opts.title)
    end

    local pane = CreateFrame("Frame", nil, section, "NineSlicePanelTemplate")
    NineSliceUtil.ApplyLayoutByName(pane, "UniqueCornersLayout", "OptionsFrame")
    pane:SetPoint("TOPLEFT", -12, -14)
    pane:SetPoint("BOTTOMRIGHT", -6, -16)

    local tabs, lists = {}, {}
    for i, name in ipairs(names) do
        local tab = CreateFrame("Button", nil, section, "MinimalTabTemplate")
        tab.Text:SetText(name)
        tab:SetSize(tab.Text:GetStringWidth() + 40, 37)
        tabs[i] = tab
    end
    -- anchored right to left from the pane's top right corner, like Graphics' Base / Raid tabs
    for i = #tabs, 1, -1 do
        if i == #tabs then
            tabs[i]:SetPoint("TOPRIGHT", section, "TOPRIGHT", -30, 10)
        else
            tabs[i]:SetPoint("TOPRIGHT", tabs[i + 1], "TOPLEFT", 0, 0)
        end
    end

    local function MakeList()
        local list = NewList(self, section)
        -- inset from the pane's border art on every side, so rows (and their highlights) stay inside it
        list.scroll:SetPoint("TOPLEFT", 8, -38)
        list.scroll:SetPoint("BOTTOMRIGHT", -20, 4)
        -- the scroll bar sits outside the pane at the page's right edge, like the Graphics page's
        list.scroll.ScrollBar:ClearAllPoints()
        list.scroll.ScrollBar:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", -SCROLLBAR_W, LIST_TOP - 4 - above)
        list.scroll.ScrollBar:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMRIGHT", -SCROLLBAR_W - 1, 9)
        self.lists[#self.lists + 1] = list
        return list
    end
    if opts.shared then
        local list = MakeList()
        for i = 1, #names do lists[i] = list end
    else
        for i = 1, #names do lists[i] = MakeList() end
    end

    local group = CreateRadioButtonGroup()
    group:AddButtons(tabs)
    local function Select(index)
        for i, list in ipairs(lists) do list.scroll:SetShown(lists[index] == list or (opts.shared and true)) end
        if opts.onSelect then opts.onSelect(index) end
        self:Refresh()
    end
    group:SelectAtIndex(1)
    Select(1)
    -- registered after the first selection, so building the page doesn't play the tab sound
    group:RegisterCallback(ButtonGroupBaseMixin.Event.Selected, function(_, _, index)
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        Select(index)
    end, self)

    self.tabGroup, self.tabButtons = group, tabs
    return lists
end

function Page:SelectTab(index)
    if self.tabGroup then self.tabGroup:SelectAtIndex(index) end
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------
function Kit.Refresh(page)
    page:Layout()
    page:Refresh()
end

-- Register in Options > AddOns, as a category or as a subcategory of parent (a category or page)
function Kit.Register(page, parent)
    page:Layout() -- values are filled in when the page is shown (saved settings may not be loaded yet)
    local category
    if parent then
        local parentCategory = parent.category or parent
        category = Settings.RegisterCanvasLayoutSubcategory(parentCategory, page.frame, page.title)
    else
        category = Settings.RegisterCanvasLayoutCategory(page.frame, page.title)
        Settings.RegisterAddOnCategory(category)
    end
    page.category = category
    return category
end

function Kit.Open(page)
    Settings.OpenToCategory(page.category:GetID())
end
