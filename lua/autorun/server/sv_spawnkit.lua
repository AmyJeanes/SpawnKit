util.AddNetworkString("spawnkit.sync")
util.AddNetworkString("spawnkit.pull")
util.AddNetworkString("spawnkit.notify")
util.AddNetworkString("spawnkit.skipped")
util.AddNetworkString("spawnkit.suppresspickups")
util.AddNetworkString("spawnkit.command")

local DATA_DIR = "spawnkit"

---@type table<string, SpawnKitData>
SpawnKit.Kits = SpawnKit.Kits or {}

---@param id string?
---@return string?
local function savePathFor(id)
    if not id or id == "0" then return nil end -- don't save invalid ids
    return DATA_DIR .. "/" .. id .. ".json"
end

-- Saved data could contain invalid data: drop bad classes, dedupe, cap to max. We intentionally keep missing
-- weapons as they may be temporarily uninstalled/disabled and may come back later
---@param raw any
---@return string[]
local function sanitizeWeapons(raw)
    local out, seen = {}, {}
    if istable(raw) then
        for _, class in ipairs(raw) do
            if isstring(class) and string.match(class, "^[%w_]+$") and not seen[class] and #out < SpawnKit.MaxWeapons then
                seen[class] = true
                out[#out + 1] = class
            end
        end
    end
    return out
end

---@param raw any
---@return table<string, number>
local function sanitizeAmmo(raw)
    local out = {}
    if istable(raw) then
        for ammoType, amount in pairs(raw) do
            if isnumber(amount) then
                local n = math.Clamp(math.floor(amount), 0, SpawnKit.MaxClips)
                if n > 0 then out[ammoType] = n end
            end
        end
    end
    return out
end

-- Drop ammo types no kit weapon uses
---@param weapons string[]
---@param ammo table<string, number>
local function pruneAmmoTable(weapons, ammo)
    local used = {}
    for _, class in ipairs(weapons) do
        for ammoType in pairs(SpawnKit.AmmoTypes(class)) do used[ammoType] = true end
    end
    for ammoType in pairs(ammo) do
        if not used[ammoType] then ammo[ammoType] = nil end
    end
end

---@param ply Player
---@return SpawnKitData
function SpawnKit.GetKit(ply)
    local id = ply:SteamID64()
    if ply:IsBot() or not id or id == "0" then
        -- Bots or invalid players get an in-memory kit that doesn't persist, also useful for testing
        local kit = ply.SpawnKitLocal
        if not kit then
            kit = { enabled = true, live = true, stripDefaults = false, weapons = {}, ammo = {}, presets = {} }
            ply.SpawnKitLocal = kit
        end
        return kit
    end

    local cached = SpawnKit.Kits[id]
    if cached then return cached end

    ---@type SpawnKitData
    local data = { enabled = true, live = true, stripDefaults = false, weapons = {}, ammo = {}, presets = {} }
    local path = savePathFor(id)
    if path and file.Exists(path, "DATA") then
        local decoded = util.JSONToTable(file.Read(path, "DATA") or "", false, true)
        if istable(decoded) then
            data.enabled = decoded.enabled ~= false
            data.live = decoded.live ~= false
            data.stripDefaults = decoded.stripDefaults == true
            data.weapons = sanitizeWeapons(decoded.weapons)
            data.ammo = sanitizeAmmo(decoded.ammo)
            pruneAmmoTable(data.weapons, data.ammo)
            if isstring(decoded.default) and table.HasValue(data.weapons, decoded.default) then data.default = decoded.default end
            if istable(decoded.presets) then
                for name, rawPreset in pairs(decoded.presets) do
                    if istable(rawPreset) then
                        local presetWeapons = sanitizeWeapons(rawPreset.weapons)
                        ---@type SpawnKitPreset
                        local preset = { weapons = presetWeapons, ammo = sanitizeAmmo(rawPreset.ammo), stripDefaults = rawPreset.stripDefaults == true }
                        if isstring(rawPreset.default) and table.HasValue(presetWeapons, rawPreset.default) then preset.default = rawPreset.default end
                        pruneAmmoTable(presetWeapons, preset.ammo)
                        data.presets[name] = preset
                    end
                end
            end
            if isstring(decoded.activePreset) and data.presets[decoded.activePreset] then data.activePreset = decoded.activePreset end
        end
    end

    SpawnKit.Kits[id] = data
    return data
end

-- Only write to file after a second of inactivity, so quick edits don't spam disk
local SAVE_DEBOUNCE = 1
---@type table<Player, number>
local saveDeadline = {}

---@param ply Player
local function writeKit(ply)
    saveDeadline[ply] = nil
    local path = savePathFor(ply:SteamID64())
    if not path then return end
    file.CreateDir(DATA_DIR)
    file.Write(path, util.TableToJSON(SpawnKit.GetKit(ply), true))
end

---@param ply Player
function SpawnKit.SaveKit(ply)
    if ply:IsBot() or not savePathFor(ply:SteamID64()) then return end
    saveDeadline[ply] = RealTime() + SAVE_DEBOUNCE
end

hook.Add("Think", "SpawnKit.FlushSaves", function()
    if not next(saveDeadline) then return end
    local now = RealTime()
    for ply, deadline in pairs(saveDeadline) do
        if now >= deadline then
            if IsValid(ply) then writeKit(ply) else saveDeadline[ply] = nil end
        end
    end
end)

-- Flush pending edits if the server stops before the debounce fires
hook.Add("ShutDown", "SpawnKit.FlushSaves", function()
    for ply in pairs(saveDeadline) do
        if IsValid(ply) then writeKit(ply) end
    end
end)

---@param ply Player
local function sync(ply)
    net.Start("spawnkit.sync")
    net.WriteString(util.TableToJSON(SpawnKit.GetKit(ply)))
    net.Send(ply)
end

---@param ply Player
---@param msg string
local function notify(ply, msg)
    net.Start("spawnkit.notify")
    net.WriteString(msg)
    net.Send(ply)
end

-- Trims spaces, lowercases, and rejects empty or non-alphanumeric/underscore. Returns nil if invalid
---@param class string?
---@return string?
local function normalize(class)
    class = string.lower(string.Trim(class or ""))
    if class == "" or not string.match(class, "^[%w_]+$") then return nil end
    return class
end

-- Trims spaces, drops quote marks and rejects empty or >32 chars. Returns nil if invalid
---@param name string?
---@return string?
local function presetName(name)
    name = string.Trim(name or "")
    name = string.match(name, '^"(.*)"$') or name
    name = string.Trim(name)
    if name == "" then return nil end
    return string.sub(name, 1, 32)
end

---@param ply Player
---@param class string
---@return boolean
local function canSpawn(ply, class)
    -- A provider weapon (SWEP.SpawnKit) has it's own logic, so we don't check Spawnable/AdminOnly
    local provider = SpawnKit.Provider(class)
    local canGive = true
    ---@type table?
    local swep = weapons.GetStored(class)
    if provider then
        canGive = not isfunction(provider.canGive) or provider.canGive(ply) ~= false
    else
        if swep then
            canGive = swep.Spawnable and (not swep.AdminOnly or ply:IsAdmin())
        else
            -- Unknown class, likely an engine weapon, let `PlayerGiveSWEP` block it if needed
            canGive = true
        end
    end
    ---@type table
    local spawninfo = swep or {}
    return canGive and hook.Run("PlayerGiveSWEP", ply, class, spawninfo) ~= false
end

---@param class string
---@return boolean
local function isKnownWeapon(class)
    -- Check Weapon list as a fallback for engine weapons that don't appear in weapons.GetStored
    return SpawnKit.Provider(class) ~= nil or weapons.GetStored(class) ~= nil or istable(list.Get("Weapon")[class])
end

---@param ply Player
---@param class string
---@param token string?
local function giveWeapon(ply, class, token)
    local provider = SpawnKit.Provider(class)
    if provider then
        provider.give(ply, token)
    -- Skip unknown weapons but keep them in the kit as they may come back later
    -- e.g. if an addon is temporarily uninstalled or disabled
    elseif isKnownWeapon(class) then
        ply:Give(class)
    end
end

-- A list of stripped weapons when strip defaults is on, so we can restore them if it's turned off
---@type table<Player, table<string, boolean>>
local strippedDefaults = {}

---@param ply Player
---@param kit SpawnKitData
local function stripToKit(ply, kit)
    local keep = {}
    for _, class in ipairs(kit.weapons) do keep[class] = true end
    local removed = strippedDefaults[ply] or {}
    strippedDefaults[ply] = removed
    local weps = ply:GetWeapons()
    for _, weapon in ipairs(weps) do
        local class = weapon:GetClass()
        if not keep[class] then
            ply:StripWeapon(class)
            removed[class] = true
        end
    end
end

---@type table<Player, table<string, number>>
local givenAmmo = {}

---@type table<Player, table<string, boolean>>
local spawnKitGave = {}

---@param kit SpawnKitData
---@param ammoType string
---@return boolean
local function kitUsesAmmo(kit, ammoType)
    for _, class in ipairs(kit.weapons) do
        if SpawnKit.AmmoTypes(class)[ammoType] then return true end
    end
    return false
end

-- Clips->rounds come from the first kit weapon (in kit order) using the ammo type, matching UI "(X/clip)" label
---@param kit SpawnKitData
---@param ammoType string
---@return number?
local function clipForType(kit, ammoType)
    for _, class in ipairs(kit.weapons) do
        local clip = SpawnKit.AmmoTypes(class)[ammoType]
        if clip then return clip end
    end
    return nil
end

-- Does a spawnable kit weapon use this type? Gates whether its ammo is given (clipForType only sizes it)
---@param ply Player
---@param kit SpawnKitData
---@param ammoType string
---@return boolean
local function spawnableUsesAmmo(ply, kit, ammoType)
    for _, class in ipairs(kit.weapons) do
        if canSpawn(ply, class) and SpawnKit.AmmoTypes(class)[ammoType] then return true end
    end
    return false
end

---@param ply Player
---@param kit SpawnKitData
---@param live boolean
local function pruneOrphanAmmo(ply, kit, live)
    for ammoType in pairs(kit.ammo) do
        if not kitUsesAmmo(kit, ammoType) then
            kit.ammo[ammoType] = nil
            if live then
                -- Reclaim any ammo we gave live for an ammo type no kit weapon uses, this prevents
                -- adding the weapon back again and getting infinite ammo by repeatedly adding/removing it
                local tally = givenAmmo[ply]
                local had = tally and tally[ammoType]
                if had and had > 0 then ply:RemoveAmmo(had, ammoType) end
                if tally then tally[ammoType] = nil end
            end
        end
    end
end

---@param ply Player
---@param ammoType string
---@param except table<string, boolean>
---@return boolean
local function heldUsesAmmo(ply, ammoType, except)
    local weps = ply:GetWeapons()
    for _, weapon in ipairs(weps) do
        local class = weapon:GetClass()
        if not except[class] and SpawnKit.AmmoTypes(class)[ammoType] then return true end
    end
    return false
end

-- Remove default ammo from a removed weapon so it doesn't double up if added back again later
---@param ply Player
---@param kit SpawnKitData
---@param removed table<string, boolean>
local function reclaimOrphanReserve(ply, kit, removed)
    for class in pairs(removed) do
        for ammoType in pairs(SpawnKit.AmmoTypes(class)) do
            if not spawnableUsesAmmo(ply, kit, ammoType) and not heldUsesAmmo(ply, ammoType, removed) then
                ply:SetAmmo(0, ammoType)
                if givenAmmo[ply] then givenAmmo[ply][ammoType] = nil end
            end
        end
    end
end

---@param ply Player
---@param class string
local function liveGiveEquip(ply, class)
    if not ply:HasWeapon(class) then
        giveWeapon(ply, class)
        spawnKitGave[ply] = spawnKitGave[ply] or {}
        spawnKitGave[ply][class] = true
    end
    if ply:HasWeapon(class) then ply:SelectWeapon(class) end
end

---@param ply Player
---@param kit SpawnKitData
---@param class string
local function liveGiveWeaponAmmo(ply, kit, class)
    local tally = givenAmmo[ply] or {}
    givenAmmo[ply] = tally
    for ammoType in pairs(SpawnKit.AmmoTypes(class)) do
        local clips = kit.ammo[ammoType]
        local clip = (clips and clips > 0) and clipForType(kit, ammoType) or nil
        if clip then
            local target = clips * clip
            local current = tally[ammoType] or 0
            local delta = target - current
            if delta > 0 then
                -- Use the actual return from GiveAmmo, so a later clip reduction only removes what we gave
                tally[ammoType] = current + ply:GiveAmmo(delta, ammoType, true)
            end
        end
    end
end

---@param ply Player
---@param kit SpawnKitData
---@param class string
local function liveGiveAdded(ply, kit, class)
    if kit.enabled and kit.live and ply:Alive() then
        liveGiveEquip(ply, class)
        liveGiveWeaponAmmo(ply, kit, class)
    end
end

---@param ply Player
---@param kit SpawnKitData
---@param class string
---@return string?
local function insertWeapon(ply, kit, class)
    if table.HasValue(kit.weapons, class) then return "present" end
    if not isKnownWeapon(class) then
        notify(ply, "Unknown weapon \"" .. class .. "\"")
        return nil
    end
    if not canSpawn(ply, class) then
        notify(ply, "This weapon can't be added to your spawn kit")
        return nil
    end
    if #kit.weapons >= SpawnKit.MaxWeapons then
        notify(ply, "Your spawn kit is full (max " .. SpawnKit.MaxWeapons .. " weapons)")
        return nil
    end
    kit.weapons[#kit.weapons + 1] = class
    return "added"
end

---@param ply Player
---@param class string
function SpawnKit.Add(ply, class)
    class = normalize(class)
    if not class then
        notify(ply, "Enter a valid weapon class to add")
        return
    end
    local kit = SpawnKit.GetKit(ply)
    local status = insertWeapon(ply, kit, class)
    if status == "present" then
        notify(ply, "This weapon is already in your spawn kit")
        return
    end
    if not status then return end
    SpawnKit.SaveKit(ply)
    sync(ply)
    liveGiveAdded(ply, kit, class)
end

---@param ply Player
---@param kit SpawnKitData
local function reselectAfterStrip(ply, kit)
    if kit.default and ply:HasWeapon(kit.default) then
        ply:SelectWeapon(kit.default)
    else
        ply:SwitchToDefaultWeapon()
    end
end

---@param ply Player
---@param class string
function SpawnKit.Remove(ply, class)
    class = normalize(class)
    if not class then
        notify(ply, "Enter a valid weapon class to remove")
        return
    end
    local kit = SpawnKit.GetKit(ply)
    if not table.HasValue(kit.weapons, class) then
        notify(ply, "\"" .. class .. "\" isn't in your spawn kit")
        return
    end
    table.RemoveByValue(kit.weapons, class)
    if kit.default == class then kit.default = nil end
    if kit.enabled and kit.live and ply:HasWeapon(class) then
        local gave = spawnKitGave[ply]
        local wasGave = gave and gave[class] or false
        if kit.stripDefaults or wasGave then
            local wasActive = IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() == class
            ply:StripWeapon(class)
            if gave then gave[class] = nil end
            if wasGave then reclaimOrphanReserve(ply, kit, { [class] = true }) end
            if wasActive then reselectAfterStrip(ply, kit) end
        end
    end
    pruneOrphanAmmo(ply, kit, kit.enabled and kit.live and ply:Alive())
    SpawnKit.SaveKit(ply)
    sync(ply)
end

---@param ply Player
---@param class string?
function SpawnKit.SetDefault(ply, class)
    local kit = SpawnKit.GetKit(ply)
    local raw = string.Trim(class or "")
    class = normalize(class)
    if not class then
        -- Clear default if empty, but if it's invalid notify the player instead
        if raw ~= "" then
            notify(ply, "Unknown weapon \"" .. raw .. "\"")
            return
        end
        kit.default = nil
        SpawnKit.SaveKit(ply)
        sync(ply)
        return
    end
    local status = insertWeapon(ply, kit, class)
    if not status then return end
    kit.default = class
    SpawnKit.SaveKit(ply)
    sync(ply)
    if status == "added" then liveGiveAdded(ply, kit, class) end
end

---@param ply Player
---@param strip boolean
function SpawnKit.SetStripDefaults(ply, strip)
    local kit = SpawnKit.GetKit(ply)
    kit.stripDefaults = strip and true or false
    SpawnKit.SaveKit(ply)
    sync(ply)
    if not (kit.enabled and kit.live and ply:Alive()) then return end
    if kit.stripDefaults then
        local active = IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() or nil
        stripToKit(ply, kit)
        if active and not ply:HasWeapon(active) then reselectAfterStrip(ply, kit) end
    else
        local removed = strippedDefaults[ply]
        if removed then
            for class in pairs(removed) do
                if not ply:HasWeapon(class) then giveWeapon(ply, class) end
            end
            strippedDefaults[ply] = nil
        end
    end
end

---@param ply Player
function SpawnKit.Clear(ply)
    local kit = SpawnKit.GetKit(ply)
    local removed = kit.weapons
    kit.weapons = {}
    kit.default = nil
    if kit.enabled and kit.live then
        local gave = spawnKitGave[ply]
        local active = IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() or nil
        local strippedActive = false
        local stripped = {}
        for _, class in ipairs(removed) do
            if ply:HasWeapon(class) and (kit.stripDefaults or (gave and gave[class])) then
                if class == active then strippedActive = true end
                if gave and gave[class] then stripped[class] = true end
                ply:StripWeapon(class)
                if gave then gave[class] = nil end
            end
        end
        reclaimOrphanReserve(ply, kit, stripped)
        if strippedActive then reselectAfterStrip(ply, kit) end
    end
    pruneOrphanAmmo(ply, kit, kit.enabled and kit.live and ply:Alive())
    SpawnKit.SaveKit(ply)
    sync(ply)
end

-- Replace the kit with the held weapons, ones SpawnKit can't re-give are skipped but reported (soft fail)
---@param ply Player
function SpawnKit.SetFromLoadout(ply)
    local kit = SpawnKit.GetKit(ply)
    ---@type string[]
    local kept = {}
    local skipped = {}
    local weps = ply:GetWeapons()
    for _, weapon in ipairs(weps) do
        local class = weapon:GetClass()
        if not table.HasValue(kept, class) and not table.HasValue(skipped, class) then
            if not canSpawn(ply, class) or #kept >= SpawnKit.MaxWeapons then
                skipped[#skipped + 1] = class
            else
                kept[#kept + 1] = class
            end
        end
    end
    kit.weapons = kept
    if kit.default and not table.HasValue(kept, kit.default) then kit.default = nil end
    -- Mark adopted held weapons as ours so a later live-remove can strip them
    local gave = spawnKitGave[ply] or {}
    spawnKitGave[ply] = gave
    for _, class in ipairs(kept) do
        if ply:HasWeapon(class) then gave[class] = true end
    end
    pruneOrphanAmmo(ply, kit, kit.enabled and kit.live and ply:Alive())
    SpawnKit.SaveKit(ply)
    sync(ply)
    if #skipped > 0 then
        net.Start("spawnkit.skipped")
        net.WriteUInt(#skipped, 8)
        for _, class in ipairs(skipped) do net.WriteString(class) end
        net.Send(ply)
    end
end

---@param ply Player
---@param ammoType string
---@param clips number
function SpawnKit.SetAmmo(ply, ammoType, clips)
    if not isstring(ammoType) then
        notify(ply, "Usage: spawnkit_ammo <ammo type> <clips>")
        return
    end
    if game.GetAmmoID(ammoType) < 0 then
        notify(ply, "Unknown ammo type \"" .. ammoType .. "\"")
        return
    end
    ammoType = SpawnKit.NormalizeAmmoType(ammoType)
    clips = math.Clamp(math.floor(clips or 0), 0, SpawnKit.MaxClips)
    local kit = SpawnKit.GetKit(ply)
    if not kitUsesAmmo(kit, ammoType) then
        notify(ply, "No weapon in your kit uses \"" .. ammoType .. "\" ammo")
        return
    end
    kit.ammo[ammoType] = clips > 0 and clips or nil
    SpawnKit.SaveKit(ply)
    -- Don't sync back to the client because it will overwrite the ammo count in the UI, only apply delta to the player if live
    if kit.enabled and kit.live and ply:Alive() then
        local clip = spawnableUsesAmmo(ply, kit, ammoType) and clipForType(kit, ammoType) or nil
        if clip then
            local target = clips * clip
            givenAmmo[ply] = givenAmmo[ply] or {}
            local current = givenAmmo[ply][ammoType] or 0
            local delta = target - current
            if delta > 0 then
                -- Use the actual return from GiveAmmo, so a later clip reduction only removes what we gave
                givenAmmo[ply][ammoType] = current + ply:GiveAmmo(delta, ammoType, true)
            elseif delta < 0 then
                ply:RemoveAmmo(-delta, ammoType)
                givenAmmo[ply][ammoType] = target
            end
        end
    end
end

-- Setup the live loadout when the kit or live mode is enabled or when switching presets
---@param ply Player
---@param kit SpawnKitData
---@param oldWeapons string[]
---@param oldStrip boolean
local function reconcileLive(ply, kit, oldWeapons, oldStrip)
    local gave = spawnKitGave[ply] or {}
    spawnKitGave[ply] = gave
    local newSet = {}
    for _, class in ipairs(kit.weapons) do newSet[class] = true end

    local active = IsValid(ply:GetActiveWeapon()) and ply:GetActiveWeapon():GetClass() or nil
    local strippedActive = false
    local stripped = {}
    for _, class in ipairs(oldWeapons) do
        if not newSet[class] and ply:HasWeapon(class) and (oldStrip or gave[class]) then
            if class == active then strippedActive = true end
            -- We never gave this, only strip-defaults is removing it - record it so strip-off can restore it
            if oldStrip and not gave[class] then
                local removed = strippedDefaults[ply] or {}
                strippedDefaults[ply] = removed
                removed[class] = true
            end
            if gave[class] then stripped[class] = true end
            ply:StripWeapon(class)
            gave[class] = nil
        end
    end
    reclaimOrphanReserve(ply, kit, stripped)

    -- Give kit weapons the player can spawn and aren't already holding, and collect their ammo types for the next step
    local spawnableType = {}
    for _, class in ipairs(kit.weapons) do
        if canSpawn(ply, class) then
            if not ply:HasWeapon(class) then
                giveWeapon(ply, class)
                gave[class] = true
            end
            for ammoType in pairs(SpawnKit.AmmoTypes(class)) do spawnableType[ammoType] = true end
        end
    end

    -- Give or remove ammo to match the kit for ammo types used by kit weapons, ignoring base ammo not given by the kit
    local tally = givenAmmo[ply] or {}
    givenAmmo[ply] = tally
    local types = {}
    for ammoType in pairs(tally) do types[ammoType] = true end
    for ammoType in pairs(kit.ammo) do types[ammoType] = true end
    for ammoType in pairs(types) do
        local clips = kit.ammo[ammoType]
        local clip = spawnableType[ammoType] and clipForType(kit, ammoType) or nil
        local target = (clips and clip) and clips * clip or 0
        local current = tally[ammoType] or 0
        local delta = target - current
        if delta > 0 then
            tally[ammoType] = current + ply:GiveAmmo(delta, ammoType, true)
        elseif delta < 0 then
            ply:RemoveAmmo(-delta, ammoType)
            tally[ammoType] = target > 0 and target or nil
        elseif target == 0 then
            tally[ammoType] = nil
        end
    end

    if kit.stripDefaults then
        stripToKit(ply, kit)
    elseif oldStrip then
        local removed = strippedDefaults[ply]
        if removed then
            for class in pairs(removed) do
                if not ply:HasWeapon(class) then giveWeapon(ply, class) end
            end
            strippedDefaults[ply] = nil
        end
    end

    if kit.default and ply:HasWeapon(kit.default) then
        ply:SelectWeapon(kit.default)
    elseif strippedActive then
        reselectAfterStrip(ply, kit)
    end
end

---@param ply Player
---@param kit SpawnKitData
---@param nowApplied boolean
---@param wasApplied boolean
local function reconcileEnabled(ply, kit, nowApplied, wasApplied)
    if nowApplied == wasApplied then return end
    if nowApplied then
        reconcileLive(ply, kit, {}, false)
    else
        local empty = { enabled = false, live = false, stripDefaults = false, weapons = {}, ammo = {}, presets = {} }
        reconcileLive(ply, empty, kit.weapons, kit.stripDefaults)
    end
end

---@param ply Player
---@param enabled boolean
function SpawnKit.SetEnabled(ply, enabled)
    local kit = SpawnKit.GetKit(ply)
    local was = kit.enabled
    kit.enabled = enabled and true or false
    SpawnKit.SaveKit(ply)
    sync(ply)
    if kit.live and ply:Alive() then reconcileEnabled(ply, kit, kit.enabled, was) end
end

---@param ply Player
---@param live boolean
function SpawnKit.SetLive(ply, live)
    local kit = SpawnKit.GetKit(ply)
    local was = kit.live
    kit.live = live and true or false
    SpawnKit.SaveKit(ply)
    sync(ply)
    -- Only apply the kit live on enable, don't remove it on disable
    if kit.enabled and kit.live and not was and ply:Alive() then
        ---@type string[]
        local old = {}
        local gave = spawnKitGave[ply]
        if gave then
            for class in pairs(gave) do old[#old + 1] = class end
        end
        reconcileLive(ply, kit, old, false)
    end
end

---@param kit SpawnKitData
---@return SpawnKitPreset
local function snapshotKit(kit)
    return {
        weapons = table.Copy(kit.weapons),
        ammo = table.Copy(kit.ammo),
        default = kit.default,
        stripDefaults = kit.stripDefaults,
    }
end

---@param ply Player
---@param name string?
function SpawnKit.SavePreset(ply, name)
    name = presetName(name)
    if not name then
        notify(ply, "Enter a name for the preset")
        return
    end
    local kit = SpawnKit.GetKit(ply)
    if not kit.presets[name] and table.Count(kit.presets) >= SpawnKit.MaxPresets then
        notify(ply, "You already have the maximum of " .. SpawnKit.MaxPresets .. " presets")
        return
    end
    kit.presets[name] = snapshotKit(kit)
    kit.activePreset = name
    SpawnKit.SaveKit(ply)
    sync(ply)
end

---@param ply Player
---@param name string?
function SpawnKit.LoadPreset(ply, name)
    name = presetName(name)
    if not name then
        notify(ply, "Enter the name of a preset to load")
        return
    end
    local kit = SpawnKit.GetKit(ply)
    local preset = kit.presets[name]
    if not preset then
        notify(ply, "You have no preset named \"" .. name .. "\"")
        return
    end

    local live = kit.enabled and kit.live and ply:Alive()
    local oldWeapons, oldStrip = kit.weapons, kit.stripDefaults

    kit.weapons = table.Copy(preset.weapons)
    kit.ammo = table.Copy(preset.ammo)
    kit.default = preset.default
    kit.stripDefaults = preset.stripDefaults
    kit.activePreset = name
    SpawnKit.SaveKit(ply)
    sync(ply)

    if live then reconcileLive(ply, kit, oldWeapons, oldStrip) end
end

---@param ply Player
---@param name string?
function SpawnKit.DeletePreset(ply, name)
    name = presetName(name)
    if not name then
        notify(ply, "Enter the name of a preset to delete")
        return
    end
    local kit = SpawnKit.GetKit(ply)
    if not kit.presets[name] then
        notify(ply, "You have no preset named \"" .. name .. "\"")
        return
    end
    kit.presets[name] = nil
    if kit.activePreset == name then kit.activePreset = nil end
    SpawnKit.SaveKit(ply)
    sync(ply)
end

---@type table<Player, boolean>
local pendingSpawn = {}

---@param ply Player
local function applyKit(ply)
    local kit = SpawnKit.GetKit(ply)
    if not kit.enabled then return end
    local gave = spawnKitGave[ply] or {}
    spawnKitGave[ply] = gave
    local tally = givenAmmo[ply] or {}
    givenAmmo[ply] = tally

    local spawnableType = {}
    for _, class in ipairs(kit.weapons) do
        if canSpawn(ply, class) then
            if not ply:HasWeapon(class) then
                giveWeapon(ply, class)
                gave[class] = true
            end
            for ammoType in pairs(SpawnKit.AmmoTypes(class)) do spawnableType[ammoType] = true end
        end
    end

    for ammoType in pairs(spawnableType) do
        local clips = kit.ammo[ammoType]
        local clip = clips and clips > 0 and clipForType(kit, ammoType) or nil
        if clip then
            local current = tally[ammoType] or 0
            local delta = clips * clip - current
            if delta > 0 then tally[ammoType] = current + ply:GiveAmmo(delta, ammoType, true) end
        end
    end

    if kit.stripDefaults then stripToKit(ply, kit) end

    if kit.default and ply:HasWeapon(kit.default) then ply:SelectWeapon(kit.default) end
end

hook.Add("PlayerLoadout", "SpawnKit", function(ply)
    givenAmmo[ply] = {}
    spawnKitGave[ply] = {}
    strippedDefaults[ply] = nil
    pendingSpawn[ply] = true
    -- Suppress client pickup sounds/notifications when the kit is applied on spawn
    local kit = SpawnKit.GetKit(ply)
    if not ply:IsBot() and kit.enabled and (#kit.weapons > 0 or next(kit.ammo)) then
        net.Start("spawnkit.suppresspickups")
        net.Send(ply)
    end
end)

hook.Add("Think", "SpawnKit.PostSpawn", function()
    for ply in pairs(pendingSpawn) do
        pendingSpawn[ply] = nil
        if IsValid(ply) and ply:Alive() then applyKit(ply) end
    end
end)

hook.Add("PlayerDisconnected", "SpawnKit", function(ply)
    if saveDeadline[ply] then writeKit(ply) end -- flush a pending edit while the cache is still live
    pendingSpawn[ply] = nil
    givenAmmo[ply] = nil
    spawnKitGave[ply] = nil
    strippedDefaults[ply] = nil
    local id = ply:SteamID64()
    if id and id ~= "0" then SpawnKit.Kits[id] = nil end
end)

net.Receive("spawnkit.pull", function(_, ply)
    if IsValid(ply) then sync(ply) end
end)

---@type table<string, fun(ply: Player, args: string[])>
local COMMANDS = {
    add = function(ply, args) SpawnKit.Add(ply, args[1]) end,
    add_held = function(ply)
        local wep = ply:GetActiveWeapon()
        if IsValid(wep) then SpawnKit.Add(ply, wep:GetClass()) else notify(ply, "You aren't holding any weapons to add") end
    end,
    remove = function(ply, args) SpawnKit.Remove(ply, args[1]) end,
    default = function(ply, args) SpawnKit.SetDefault(ply, args[1]) end,
    clear = function(ply) SpawnKit.Clear(ply) end,
    set_current = function(ply) SpawnKit.SetFromLoadout(ply) end,
    enabled = function(ply, args) SpawnKit.SetEnabled(ply, tobool(args[1])) end,
    live = function(ply, args) SpawnKit.SetLive(ply, tobool(args[1])) end,
    stripdefaults = function(ply, args) SpawnKit.SetStripDefaults(ply, tobool(args[1])) end,
    ammo = function(ply, args) SpawnKit.SetAmmo(ply, args[1], tonumber(args[2]) or 0) end,
    preset_save = function(ply, args) SpawnKit.SavePreset(ply, args[1]) end,
    preset_load = function(ply, args) SpawnKit.LoadPreset(ply, args[1]) end,
    preset_delete = function(ply, args) SpawnKit.DeletePreset(ply, args[1]) end,
    list = function(ply)
        local kit = SpawnKit.GetKit(ply)
        ply:PrintMessage(HUD_PRINTCONSOLE, "SpawnKit (" .. (kit.enabled and "enabled" or "disabled") .. "):")
        if #kit.weapons == 0 then
            ply:PrintMessage(HUD_PRINTCONSOLE, "  (no weapons)")
        else
            for i, class in ipairs(kit.weapons) do
                ply:PrintMessage(HUD_PRINTCONSOLE, "  " .. i .. ". " .. class .. (kit.default == class and "  (default)" or ""))
            end
        end
        local names = {}
        for n in pairs(kit.presets) do names[#names + 1] = n end
        table.sort(names)
        if #names > 0 then
            ply:PrintMessage(HUD_PRINTCONSOLE, "Presets:")
            for _, n in ipairs(names) do
                ply:PrintMessage(HUD_PRINTCONSOLE, "  - " .. n .. (kit.activePreset == n and "  (active)" or ""))
            end
        end
    end,
}

net.Receive("spawnkit.command", function(_, ply)
    if not IsValid(ply) then return end
    local handler = COMMANDS[net.ReadString()]
    if not handler then return end
    ---@type string[]
    local args = {}
    for i = 1, math.min(net.ReadUInt(8), 32) do args[i] = net.ReadString() end
    handler(ply, args)
end)

concommand.Add("spawnkit_reload", function(ply)
    if IsValid(ply) and not ply:IsSuperAdmin() then
        notify(ply, "spawnkit_reload requires superadmin")
        return
    end
    SpawnKit.Kits = {}
    local humans = player.GetHumans()
    for _, p in ipairs(humans) do
        saveDeadline[p] = nil
        sync(p)
    end
    local msg = "[SpawnKit] Reloaded kits from disk for " .. #humans .. " player(s)"
    if IsValid(ply) and not ply:IsListenServerHost() then
        ply:PrintMessage(HUD_PRINTCONSOLE, msg)
    end
    print(msg)
end)
