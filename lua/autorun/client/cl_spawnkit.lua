---@type SpawnKitData
SpawnKit.MyKit = SpawnKit.MyKit or { enabled = true, live = true, stripDefaults = false, weapons = {}, ammo = {}, presets = {} }

-- Unicode for tick and star used to indicate a weapon is in the kit and/or is the default
local MARK_IN_KIT = utf8.char(0x2713)
local MARK_DEFAULT = utf8.char(0x2605)

local AMMO_HIGHLIGHT_ALPHA = 40
local USED_BY_COLOR = Color(140, 140, 140)

-- Declare these internal fields so we can use them without warnings
---@class DNumberWang
---@field Up DButton
---@field Down DButton

---@param class string
---@return string
local function prettyName(class)
    local reg = list.Get("Weapon")[class]
    if reg and isstring(reg.PrintName) and reg.PrintName ~= "" then return language.GetPhrase(reg.PrintName) end
    local swep = weapons.GetStored(class)
    if swep and isstring(swep.PrintName) and swep.PrintName ~= "" then return language.GetPhrase(swep.PrintName) end
    return class
end

local function pull()
    net.Start("spawnkit.pull")
    net.SendToServer()
end

---@param checkbox DCheckBoxLabel
---@param text string
local function checkboxTooltip(checkbox, text)
    checkbox:SetTooltip(text)
    -- Need to set tooltip on label/button too or it doesn't work
    checkbox.Label:SetTooltip(text)
    checkbox.Button:SetTooltip(text)
end

function SpawnKit.RefreshTicks()
    local inKit = {}
    for _, class in ipairs(SpawnKit.MyKit.weapons) do inKit[class] = true end
    local default = SpawnKit.MyKit.default
    for class, line in pairs(SpawnKit.WeaponLines or {}) do
        if IsValid(line) then
            line:SetColumnText(1, inKit[class] and MARK_IN_KIT or "")
            line:SetColumnText(2, default == class and MARK_DEFAULT or "")
        end
    end
end

---@param raw string?
---@return string
local function categoryName(raw)
    if not isstring(raw) or raw == "" then return "Other" end
    return language.GetPhrase(raw)
end

function SpawnKit.BuildCatalog()
    local isAdmin = LocalPlayer():IsAdmin()
    local entries = {}
    for class, wep in pairs(list.Get("Weapon")) do
        -- Only offer spawnable weapons where the class matches the registered weapon,
        -- some addons register multiple fake classes for the same weapon which we ignore
        if class == wep.ClassName then
            -- Matches server-side logic in canSpawn (aside from the PlayerGiveSWEP hook which is server only)
            local provider = SpawnKit.Provider(class)
            local offer
            if provider then
                offer = not isfunction(provider.canGive) or provider.canGive(LocalPlayer()) ~= false
            else
                local swep = weapons.GetStored(class)
                offer = not swep or (swep.Spawnable and not (swep.AdminOnly and not isAdmin))
            end
            if offer then
                local printName = (isstring(wep.PrintName) and wep.PrintName ~= "") and wep.PrintName or class
                entries[#entries + 1] = { class = class, name = language.GetPhrase(printName), category = categoryName(wep.Category) }
            end
        end
    end
    SpawnKit.Catalog = entries
    ---@type table<string, boolean>
    local set = {}
    for _, entry in ipairs(entries) do set[entry.class] = true end
    SpawnKit.CatalogSet = set
end

---@param listView DListView
local function wireList(listView)
    local bar = listView.VBar
    if bar then
        bar:SetWide(0)
        bar.SetUp = function() bar:SetWide(0) end
    end

    ---@param w number
    ---@param h number
    function listView:Paint(w, h)
        -- Cut off the bottom of the list view to drop part of the border which makes it look better in a list of lists
        local x, y = self:LocalToScreen(0, 0)
        render.SetScissorRect(x, y, x + w, y + h - 1, true)
        derma.SkinHook("Paint", "ListView", self, w, h)
        render.SetScissorRect(0, 0, 0, 0, false)
    end

    ---@param line DListView_Line
    listView.DoDoubleClick = function(_, _, line)
        local class = SpawnKit.ClassOf[line]
        if not class then return end
        RunConsoleCommand(table.HasValue(SpawnKit.MyKit.weapons, class) and "spawnkit_remove" or "spawnkit_add", class)
    end

    ---@param line DListView_Line
    listView.OnRowRightClick = function(_, _, line)
        local class = SpawnKit.ClassOf[line]
        if not class then return end
        local inKit = table.HasValue(SpawnKit.MyKit.weapons, class)
        local isDefault = SpawnKit.MyKit.default == class
        local menu = DermaMenu()
        menu:AddOption(inKit and "Remove from spawn kit" or "Add to spawn kit", function()
            RunConsoleCommand(inKit and "spawnkit_remove" or "spawnkit_add", class)
        end):SetIcon(inKit and "icon16/delete.png" or "icon16/add.png")
        menu:AddOption(isDefault and "Clear default weapon" or "Set as default", function()
            RunConsoleCommand("spawnkit_default", isDefault and "" or class)
        end):SetIcon(isDefault and "icon16/cancel.png" or "icon16/star.png")
        menu:Open()
    end

    -- Clear other list selections when one is clicked, so only one weapon from any list can be selected at a time
    ---@param line DListView_Line
    function listView:OnRowSelected(_, line)
        if SpawnKit.ClearingSelection then return end
        SpawnKit.ClearingSelection = true
        for _, other in ipairs(SpawnKit.ListViews or {}) do
            if other ~= self and IsValid(other) then other:ClearSelection() end
        end
        SpawnKit.ClearingSelection = false
        SpawnKit.HighlightAmmo(SpawnKit.ClassOf[line])
    end
end

---@param name string
---@param class string
---@param category string
---@param filter string
---@return boolean
local function matchesFilter(name, class, category, filter)
    if filter == "" then return true end
    return string.find(string.lower(name), filter, 1, true) ~= nil
        or string.find(string.lower(class), filter, 1, true) ~= nil
        or string.find(string.lower(category), filter, 1, true) ~= nil
end

---@param filter string?
function SpawnKit.Repopulate(filter)
    local catList = SpawnKit.List
    if not IsValid(catList) then return end
    filter = string.lower(filter or "")
    for _, child in ipairs(catList:GetCanvas():GetChildren()) do
        -- Panels aren't removed till end of frame, so hide it now to avoid layout issues
        child:SetVisible(false)
        child:Remove()
    end
    SpawnKit.WeaponLines = {}
    ---@type table<DListView_Line, string>
    SpawnKit.ClassOf = {}
    ---@type DListView[]
    SpawnKit.ListViews = {}
    SpawnKit.HighlightAmmo(nil) -- rebuilding the list clears its selection, so drop ammo highlights

    local shown, byCat = {}, {}
    ---@param entry table
    local function place(entry)
        if not matchesFilter(entry.name, entry.class, entry.category, filter) then return end
        byCat[entry.category] = byCat[entry.category] or {}
        byCat[entry.category][#byCat[entry.category] + 1] = entry
    end
    for _, entry in ipairs(SpawnKit.Catalog or {}) do
        shown[entry.class] = true
        place(entry)
    end
    for _, class in ipairs(SpawnKit.MyKit.weapons) do
        if not shown[class] then
            shown[class] = true
            local reg = list.Get("Weapon")[class]
            place({ class = class, name = prettyName(class), category = categoryName(reg and reg.Category) })
        end
    end

    -- One collapsible section per non-empty category (alphabetical), weapons sorted by name within
    local cats = {}
    for cat in pairs(byCat) do cats[#cats + 1] = cat end
    table.sort(cats, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, cat in ipairs(cats) do
        local entries = byCat[cat]
        table.sort(entries, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
        local listView = vgui.Create("DListView")
        listView:SetMultiSelect(false)
        listView:SetHideHeaders(true)
        listView:AddColumn(""):SetFixedWidth(18)
        listView:AddColumn(""):SetFixedWidth(18)
        listView:AddColumn("Weapon")
        wireList(listView)
        SpawnKit.ListViews[#SpawnKit.ListViews + 1] = listView
        for _, entry in ipairs(entries) do
            local line = listView:AddLine("", "", entry.name)
            line:SetTooltip(entry.class)
            SpawnKit.ClassOf[line] = entry.class
            SpawnKit.WeaponLines[entry.class] = line
        end
        listView:SetTall(#entries * listView:GetDataHeight())
        catList:Add(cat):SetContents(listView)
    end
    SpawnKit.RefreshTicks()
end

-- Is this the same (order-independent) set of weapons? Used to tell whether a loaded preset has unsaved edits
---@param a string[]
---@param b string[]
---@return boolean
local function sameWeapons(a, b)
    if #a ~= #b then return false end
    local set = {}
    for _, class in ipairs(a) do set[class] = true end
    for _, class in ipairs(b) do if not set[class] then return false end end
    return true
end

---@param a table<string, number>
---@param b table<string, number>
---@return boolean
local function sameAmmo(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

---@return boolean
local function presetModified()
    local kit = SpawnKit.MyKit
    local preset = kit.activePreset and (kit.presets or {})[kit.activePreset]
    if not preset then return false end
    return kit.default ~= preset.default
        or (kit.stripDefaults and true or false) ~= (preset.stripDefaults and true or false)
        or not sameWeapons(kit.weapons, preset.weapons or {})
        or not sameAmmo(kit.ammo, preset.ammo or {})
end

function SpawnKit.UpdatePresetMarker()
    local combo = SpawnKit.PresetBox
    if not IsValid(combo) then return end
    local name = SpawnKit.MyKit.activePreset
    local modified = presetModified()
    -- Don't trigger when we're updating state, only from real player action
    SpawnKit.ApplyingPreset = true
    combo:SetValue(name and (modified and (name .. " *") or name) or "")
    SpawnKit.ApplyingPreset = false
    if IsValid(SpawnKit.PresetDelete) then SpawnKit.PresetDelete:SetEnabled(name ~= nil) end
    if IsValid(SpawnKit.PresetRevert) then SpawnKit.PresetRevert:SetEnabled(modified) end
end

function SpawnKit.RefreshPresets()
    local combo = SpawnKit.PresetBox
    if not IsValid(combo) then return end
    combo:Clear()
    local names = {}
    for n in pairs(SpawnKit.MyKit.presets or {}) do names[#names + 1] = n end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    for _, n in ipairs(names) do combo:AddChoice(n) end
    SpawnKit.UpdatePresetMarker()
end

-- Class of the currently selected catalogue row, nil if none
---@return string?
local function selectedClass()
    for _, lv in ipairs(SpawnKit.ListViews or {}) do
        if IsValid(lv) then
            local _, line = lv:GetSelectedLine()
            if IsValid(line) then return SpawnKit.ClassOf[line] end
        end
    end
end

function SpawnKit.Rebuild()
    if IsValid(SpawnKit.EnabledBox) then
        -- Don't trigger when we're updating state, only from real player action
        SpawnKit.ApplyingEnabled = true
        SpawnKit.EnabledBox:SetChecked(SpawnKit.MyKit.enabled)
        SpawnKit.ApplyingEnabled = false
    end
    if IsValid(SpawnKit.LiveBox) then
        SpawnKit.ApplyingLive = true
        SpawnKit.LiveBox:SetChecked(SpawnKit.MyKit.live)
        SpawnKit.ApplyingLive = false
    end
    if IsValid(SpawnKit.StripBox) then
        SpawnKit.ApplyingStrip = true
        SpawnKit.StripBox:SetChecked(SpawnKit.MyKit.stripDefaults)
        SpawnKit.ApplyingStrip = false
    end
    -- Only rebuild the list when we have to e.g. preset load or search filter change
    local searchText = IsValid(SpawnKit.Search) and SpawnKit.Search:GetText() or ""
    local filter = string.lower(searchText)
    local catalog = SpawnKit.CatalogSet or {}
    local lines = SpawnKit.WeaponLines or {}
    local wantSynthetic = {}
    local structural = false
    for _, c in ipairs(SpawnKit.MyKit.weapons) do
        if not catalog[c] then
            local reg = list.Get("Weapon")[c]
            if matchesFilter(prettyName(c), c, categoryName(reg and reg.Category), filter) then
                wantSynthetic[c] = true
                if not lines[c] then structural = true end
            end
        end
    end
    if not structural then
        for c, line in pairs(lines) do
            if IsValid(line) and not catalog[c] and not wantSynthetic[c] then
                structural = true
                break
            end
        end
    end
    if structural then
        SpawnKit.Repopulate(searchText)
    else
        SpawnKit.RefreshTicks()
    end
    SpawnKit.HighlightAmmo(selectedClass())
    SpawnKit.RebuildAmmo()
    SpawnKit.RefreshPresets()
end

---@param class string?
function SpawnKit.HighlightAmmo(class)
    local inKit = class ~= nil and table.HasValue(SpawnKit.MyKit.weapons, class)
    SpawnKit.SelectedAmmo = inKit and SpawnKit.AmmoTypes(class) or {}
end

-- Recompute layout up the panel tree to the scroll panel, so the scrollbar is correct after a section expands/collapses
---@param from Panel
local function reflowUp(from)
    local panel = from
    while IsValid(panel) do
        panel:InvalidateLayout(true)
        if panel.VBar then break end -- reached the scroll panel, its bar recomputes on this layout
        panel = panel:GetParent()
    end
end

---@param form DForm
local function instantCollapse(form)
    function form:Toggle()
        self:SetExpanded(not self:GetExpanded())
        self:InvalidateLayout(true)
        reflowUp(self)
    end
end

function SpawnKit.RebuildAmmo()
    local box = SpawnKit.AmmoBox
    if not IsValid(box) then return end
    box:Clear()
    -- Ensure number fields are scrollable, otherwise the spawnmenu can sometimes block mouse input until re-opening it
    box:SetMouseInputEnabled(true)

    -- usedByCat[ammoType][category] = {display names}, for the "Used by" lines grouped by category
    ---@type table<string, boolean>
    local seen = {}
    ---@type string[]
    local order = {}
    ---@type table<string, number>
    local clipOf = {}
    ---@type table<string, table<string, string[]>>
    local usedByCat = {}
    for _, class in ipairs(SpawnKit.MyKit.weapons) do
        local reg = list.Get("Weapon")[class]
        local cat = categoryName(reg and reg.Category)
        for ammoType, clip in pairs(SpawnKit.AmmoTypes(class)) do
            if not seen[ammoType] then
                seen[ammoType] = true
                order[#order + 1] = ammoType
            end
            if not clipOf[ammoType] then clipOf[ammoType] = clip end
            local byCat = usedByCat[ammoType]
            if not byCat then
                byCat = {}
                usedByCat[ammoType] = byCat
            end
            local names = byCat[cat] or {}
            byCat[cat] = names
            names[#names + 1] = prettyName(class)
        end
    end
    table.sort(order)

    ---@param ammoType string
    ---@return string[]
    local function usedByLines(ammoType)
        local byCat = usedByCat[ammoType] or {}
        local cats = {}
        for cat in pairs(byCat) do cats[#cats + 1] = cat end
        table.sort(cats)
        local lines = {}
        for _, cat in ipairs(cats) do
            local names = byCat[cat] or {}
            table.sort(names)
            lines[#lines + 1] = cat .. ": " .. table.concat(names, ", ")
        end
        return lines
    end

    local has = #order > 0
    if IsValid(SpawnKit.AmmoForm) then SpawnKit.AmmoForm:SetVisible(has) end
    if not has then box:SetTall(0) reflowUp(box) return end

    local ammo = SpawnKit.MyKit.ammo
    local totalH = 0
    for _, ammoType in ipairs(order) do
        -- One panel per ammo type (name row + dim "used by" lines) so the number box centres against all of it
        local lines = usedByLines(ammoType)
        local entryH = 24 + #lines * 14
        local entry = vgui.Create("DPanel", box)
        entry:SetMouseInputEnabled(true) -- see the box note above: keep the number field scrollable
        entry:Dock(TOP)
        entry:DockMargin(0, 4, 0, 0)
        entry:SetTall(entryH)
        entry:SetPaintBackground(false)
        -- Tint the entry while a selected weapon uses this type, in the skin's text-highlight colour
        ---@param w number
        ---@param h number
        function entry:Paint(w, h)
            if not (SpawnKit.SelectedAmmo or {})[ammoType] then return end
            local skin = self:GetSkin()
            local color = skin and skin.colTextEntryTextHighlight
            if color then
                surface.SetDrawColor(color.r, color.g, color.b, AMMO_HIGHLIGHT_ALPHA)
                surface.DrawRect(0, 0, w, h)
            end
        end

        local clip = clipOf[ammoType] or 1
        local pad = math.floor((entryH - 20) / 2)
        local wang = vgui.Create("DNumberWang", entry)
        wang:Dock(RIGHT)
        wang:DockMargin(0, pad, 6, pad)
        wang:SetWide(64)
        wang:SetMinMax(0, SpawnKit.MaxClips)
        wang:SetDecimals(0)
        wang:SetValue(ammo[ammoType] or 0)
        -- Disable double clicks so every click steps the value, or scrolling anywhere on it steps it too
        wang.Up:SetDoubleClickingEnabled(false)
        wang.Down:SetDoubleClickingEnabled(false)
        ---@param delta number
        wang.OnMouseWheeled = function(_, delta)
            local val = math.Clamp(math.floor(wang:GetValue() + delta), 0, SpawnKit.MaxClips)
            wang:SetValue(val)
            -- SetPaint skips while focused, so refresh the text manually while focused or the number will freeze
            wang:SetText(Format("%i", val))
            wang:SetCaretPos(#wang:GetText())
            return true
        end
        ---@param val number
        wang.OnValueChanged = function(_, val)
            val = math.floor(val)
            ammo[ammoType] = val > 0 and val or nil
            RunConsoleCommand("spawnkit_ammo", ammoType, tostring(val))
            SpawnKit.UpdatePresetMarker() -- ammo edits don't sync back, so refresh the marker here
        end

        local label = vgui.Create("DLabel", entry)
        label:Dock(TOP)
        label:SetTall(24)
        label:DockMargin(6, 0, 0, 0)
        label:SetDark(true)
        local name = SpawnKit.AmmoName(ammoType)
        label:SetText(clip > 1 and (name .. " (" .. clip .. "/clip)") or name)

        for _, line in ipairs(lines) do
            local sub = vgui.Create("DLabel", entry)
            sub:Dock(TOP)
            sub:DockMargin(14, 0, 0, 0)
            sub:SetTall(14)
            sub:SetTextColor(USED_BY_COLOR)
            sub:SetText(line)
        end
        totalH = totalH + entryH + 4
    end
    box:SetTall(totalH + 8)
    reflowUp(box)
end

-- When the panel is switched between the spawnmenu and context menu the layout can get into
-- a weird state, so we wait for the width to settle and force a relayout after open
local relayoutDeadline = 0
local function ammoRelayoutThink()
    local box = SpawnKit.AmmoBox
    if not IsValid(box) or RealTime() > relayoutDeadline then
        hook.Remove("Think", "SpawnKit.AmmoRelayout")
        return
    end
    if box:GetWide() > 64 then -- ignore tiny incorrect widths while its rebuilding
        box:InvalidateChildren(true)
        hook.Remove("Think", "SpawnKit.AmmoRelayout")
    end
end

local function relayoutAmmoSoon()
    if not IsValid(SpawnKit.AmmoBox) then return end
    relayoutDeadline = RealTime() + 0.5 -- timeout in case width never settles
    hook.Add("Think", "SpawnKit.AmmoRelayout", ammoRelayoutThink)
end

hook.Add("ContextMenuOpened", "SpawnKit.AmmoRelayout", relayoutAmmoSoon)
hook.Add("SpawnMenuOpen", "SpawnKit.AmmoRelayout", relayoutAmmoSoon)

---@param panel ControlPanel
function SpawnKit.BuildPanel(panel)
    panel:ClearControls()
    panel:SetLabel("SpawnKit")
    SpawnKit.Panel = panel

    panel:Help("SpawnKit allows you to customize your loadout weapons, ammo, and selected weapon that you spawn with.")

    -- Manual checkbox, not panel:CheckBox, to avoid convar binding + its OnChange-on-build
    local enabled = vgui.Create("DCheckBoxLabel")
    enabled:SetText("Enable spawn kit")
    enabled:SetDark(true)
    checkboxTooltip(enabled, "Give your kit weapons on every spawn, on top of your normal loadout")
    ---@param val boolean
    enabled.OnChange = function(_, val)
        if SpawnKit.ApplyingEnabled then return end
        RunConsoleCommand("spawnkit_enabled", val and "1" or "0")
    end
    panel:AddItem(enabled)
    SpawnKit.EnabledBox = enabled

    local live = vgui.Create("DCheckBoxLabel")
    live:SetText("Update spawn kit live")
    live:SetDark(true)
    checkboxTooltip(live, "Apply kit changes to you immediately, not just on your next spawn")
    ---@param val boolean
    live.OnChange = function(_, val)
        if SpawnKit.ApplyingLive then return end
        RunConsoleCommand("spawnkit_live", val and "1" or "0")
    end
    panel:AddItem(live)
    SpawnKit.LiveBox = live

    -- Preset row: dropdown to select kits, save icon, undo icon and delete icon
    local presetRow = vgui.Create("DPanel")
    presetRow:SetPaintBackground(false)
    presetRow:SetTall(24)
    panel:AddItem(presetRow)

    local presetLabel = vgui.Create("DLabel", presetRow)
    presetLabel:SetText("Presets:")
    presetLabel:SetDark(true)
    presetLabel:SetContentAlignment(4)
    presetLabel:SizeToContents()
    presetLabel:Dock(LEFT)
    presetLabel:DockMargin(0, 0, 4, 0)

    local del = vgui.Create("DImageButton", presetRow)
    del:SetImage("icon16/delete.png")
    del:SetTooltip("Delete the selected preset")
    del:Dock(RIGHT)
    del:SetWide(16)
    del:DockMargin(0, 4, 2, 4)
    SpawnKit.PresetDelete = del

    local save = vgui.Create("DImageButton", presetRow)
    save:SetImage("icon16/disk.png")
    save:SetTooltip("Save the current kit as a preset")
    save:Dock(RIGHT)
    save:SetWide(16)
    save:DockMargin(0, 4, 8, 4)

    local undo = vgui.Create("DImageButton", presetRow)
    undo:SetImage("icon16/arrow_undo.png")
    undo:SetTooltip("Undo unsaved changes to this preset")
    undo:Dock(RIGHT)
    undo:SetWide(16)
    undo:DockMargin(0, 4, 8, 4)
    undo:SetEnabled(false)
    undo.DoClick = function()
        local name = SpawnKit.MyKit.activePreset
        if name then RunConsoleCommand("spawnkit_preset_load", name) end
    end
    SpawnKit.PresetRevert = undo

    local combo = vgui.Create("DComboBox", presetRow)
    combo:SetSortItems(false)
    combo:Dock(FILL)
    combo:DockMargin(0, 0, 8, 0)
    SpawnKit.PresetBox = combo

    ---@param value string
    combo.OnSelect = function(_, _, value)
        if SpawnKit.ApplyingPreset then return end
        local active = SpawnKit.MyKit.activePreset
        if value == active then
            SpawnKit.UpdatePresetMarker() -- the pick blanked the " *", put it back
            return
        end
        if active and presetModified() then
            -- Confirm before switching away from a preset with unsaved edits
            SpawnKit.UpdatePresetMarker()
            Derma_Query("Save your changes to \"" .. active .. "\" before switching to \"" .. value .. "\"?",
                "Unsaved changes",
                "Save", function()
                    RunConsoleCommand("spawnkit_preset_save", active)
                    RunConsoleCommand("spawnkit_preset_load", value)
                end,
                "Discard", function() RunConsoleCommand("spawnkit_preset_load", value) end,
                "Cancel")
            return
        end
        RunConsoleCommand("spawnkit_preset_load", value)
    end

    save.DoClick = function()
        ---@param text string
        local function onConfirm(text)
            text = string.Trim(text or "")
            if text ~= "" then RunConsoleCommand("spawnkit_preset_save", text) end
        end
        Derma_StringRequest("Save preset", "Enter a name for this preset:", SpawnKit.MyKit.activePreset or "", onConfirm)
    end

    del.DoClick = function()
        local name = SpawnKit.MyKit.activePreset
        if not name then return end
        Derma_Query("Delete the preset \"" .. name .. "\"?", "Delete preset",
            "Delete", function() RunConsoleCommand("spawnkit_preset_delete", name) end,
            "Cancel")
    end

    -- Off by default: makes the kit your complete spawn loadout, stripping gamemode defaults
    local strip = vgui.Create("DCheckBoxLabel")
    strip:SetText("Remove default weapons from kit")
    strip:SetDark(true)
    checkboxTooltip(strip, "Only spawn with the weapons selected here, other default weapons will be removed on spawn")
    ---@param val boolean
    strip.OnChange = function(_, val)
        if SpawnKit.ApplyingStrip then return end
        RunConsoleCommand("spawnkit_stripdefaults", val and "1" or "0")
    end
    panel:AddItem(strip)
    SpawnKit.StripBox = strip

    local addHeld = panel:Button("Add current weapon to kit")
    addHeld.DoClick = function()
        local wep = LocalPlayer():GetActiveWeapon()
        if IsValid(wep) and table.HasValue(SpawnKit.MyKit.weapons, wep:GetClass()) then
            RunConsoleCommand("spawnkit_remove", wep:GetClass())
        else
            RunConsoleCommand("spawnkit_add_held")
        end
    end
    function addHeld:Think()
        local wep = LocalPlayer():GetActiveWeapon()
        local inKit = IsValid(wep) and table.HasValue(SpawnKit.MyKit.weapons, wep:GetClass())
        local label = inKit and "Remove current weapon from kit" or "Add current weapon to kit"
        if self:GetText() ~= label then self:SetText(label) end
    end

    local fromLoadout = panel:Button("Set kit to current loadout")
    fromLoadout.DoClick = function() RunConsoleCommand("spawnkit_set_current") end

    local clear = panel:Button("Remove all from kit")
    clear.DoClick = function() RunConsoleCommand("spawnkit_clear") end

    local weaponsForm = vgui.Create("DForm")
    weaponsForm:SetLabel("Weapons")
    panel:AddItem(weaponsForm)
    instantCollapse(weaponsForm)

    weaponsForm:Help("Double-click a weapon to add or remove it, or right-click to set your spawn default. " .. MARK_IN_KIT .. " = in spawn kit, " .. MARK_DEFAULT .. " = default (auto-equipped on spawn).")

    local search = vgui.Create("DTextEntry")
    search:SetUpdateOnType(true)
    search:SetPlaceholderText("Search weapons...")

    local clearBtn = vgui.Create("DButton", search)
    clearBtn:SetText("")
    clearBtn:SetImage("icon16/cross.png")
    clearBtn:SetPaintBackground(false)
    clearBtn:SetVisible(false)

    ---@param val string
    local function applySearch(val)
        clearBtn:SetVisible(val ~= "")
        SpawnKit.Repopulate(val)
    end
    ---@param val string
    search.OnValueChange = function(_, val) applySearch(val) end
    clearBtn.DoClick = function()
        search:SetText("")
        applySearch("")
    end
    local basePerformLayout = search.PerformLayout
    ---@param w number
    ---@param h number
    function search:PerformLayout(w, h)
        if basePerformLayout then basePerformLayout(self, w, h) end
        clearBtn:SetSize(h, h)
        clearBtn:SetPos(w - h, 0)
    end

    weaponsForm:AddItem(search)
    SpawnKit.Search = search

    local catList = vgui.Create("DCategoryList")
    catList:SetTall(300)
    weaponsForm:AddItem(catList)
    SpawnKit.List = catList

    local ammoForm = vgui.Create("DForm")
    ammoForm:SetLabel("Extra ammo clips")
    panel:AddItem(ammoForm)
    SpawnKit.AmmoForm = ammoForm
    instantCollapse(ammoForm)

    ammoForm:Help("Add extra ammo clips to your kit. Most weapons already come with some ammo, so this is added on top of that.")

    local ammo = vgui.Create("DPanel")
    ammo:SetPaintBackground(false)
    ammoForm:AddItem(ammo)
    SpawnKit.AmmoBox = ammo

    pull()
    SpawnKit.BuildCatalog()
    SpawnKit.Repopulate("")
    SpawnKit.Rebuild()
end

net.Receive("spawnkit.sync", function()
    local data = util.JSONToTable(net.ReadString() or "", false, true)
    if not istable(data) then return end

    local ammo = {}
    if istable(data.ammo) then
        for ammoType, amount in pairs(data.ammo) do ammo[ammoType] = amount end
    end
    local presets = {}
    if istable(data.presets) then
        for name, preset in pairs(data.presets) do
            if istable(preset) then
                local presetAmmo = {}
                if istable(preset.ammo) then
                    for ammoType, amount in pairs(preset.ammo) do presetAmmo[ammoType] = amount end
                end
                presets[name] = {
                    weapons = istable(preset.weapons) and preset.weapons or {},
                    ammo = presetAmmo,
                    default = isstring(preset.default) and preset.default or nil,
                    stripDefaults = preset.stripDefaults == true,
                }
            end
        end
    end
    SpawnKit.MyKit = {
        enabled = data.enabled ~= false,
        live = data.live ~= false,
        stripDefaults = data.stripDefaults == true,
        weapons = istable(data.weapons) and data.weapons or {},
        ammo = ammo,
        default = isstring(data.default) and data.default or nil,
        presets = presets,
        activePreset = isstring(data.activePreset) and data.activePreset or nil,
    }
    SpawnKit.Rebuild()
end)

---@param msg string
local function clientNotify(msg)
    surface.PlaySound("buttons/button10.wav")
    print("[SpawnKit] " .. msg)
    notification.AddLegacy(msg, NOTIFY_ERROR, 4)
end

net.Receive("spawnkit.notify", function()
    clientNotify(net.ReadString())
end)

-- "Set kit to current loadout" reports the weapons it couldn't add as classes, name them here
net.Receive("spawnkit.skipped", function()
    local names = {}
    for _ = 1, net.ReadUInt(8) do names[#names + 1] = prettyName(net.ReadString()) end
    if #names > 0 then clientNotify("Couldn't add: " .. table.concat(names, ", ")) end
end)

-- Suppress HUD weapon/ammo pickup notifications while the kit is being applied to avoid spamming notifications
local suppressPickupsUntil = 0
net.Receive("spawnkit.suppresspickups", function()
    suppressPickupsUntil = RealTime() + 1
end)

hook.Add("HUDWeaponPickedUp", "SpawnKit.SuppressSpawnPickups", function()
    if RealTime() < suppressPickupsUntil then return true end
end)

hook.Add("HUDAmmoPickedUp", "SpawnKit.SuppressSpawnPickups", function()
    if RealTime() < suppressPickupsUntil then return true end
end)

hook.Add("InitPostEntity", "SpawnKit.Pull", pull)

hook.Add("PopulateToolMenu", "SpawnKit", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "spawnkit", "SpawnKit", "", "", SpawnKit.BuildPanel)
end)
