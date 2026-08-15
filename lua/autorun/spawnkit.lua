SpawnKit = SpawnKit or {}

SpawnKit.MaxWeapons = 32
SpawnKit.MaxClips = 99
SpawnKit.MaxPresets = 16

---@class SpawnKitData
---@field enabled boolean
---@field live boolean apply kit edits to the player immediately
---@field stripDefaults boolean on spawn, strip everything not in the kit
---@field weapons string[]
---@field ammo table<string, number> ammo type -> number of clips
---@field default string? class auto-equipped on spawn
---@field presets table<string, SpawnKitPreset>
---@field activePreset string? name of the loaded/last-saved preset

---@class SpawnKitPreset
---@field weapons string[]
---@field ammo table<string, number>
---@field default string?
---@field stripDefaults boolean

---@class SpawnKitProvider
---@field give fun(ply: Player, token: string?)
---@field canGive? fun(ply: Player): boolean

---@param class string
---@return SpawnKitProvider?
function SpawnKit.Provider(class)
    local swep = weapons.GetStored(class)
    local provider = istable(swep) and istable(swep.SpawnKit) and swep.SpawnKit or nil
    -- give function is required, canGive is optional
    return (provider and isfunction(provider.give)) and provider or nil
end

---@param ammoType string
---@return string
function SpawnKit.NormalizeAmmoType(ammoType)
    local id = game.GetAmmoID(ammoType)
    if id and id >= 0 then
        local name = game.GetAmmoName(id)
        if isstring(name) and name ~= "" then return name end
    end
    return ammoType
end

-- For some reason weapon_slam doesn't have a script file to provide it's ammo type and clip size
local ENGINE_FALLBACK = {
    weapon_slam = { primary_ammo = "slam", clip_size = 1 },
}

---@type table<string, table|false>
local scriptCache = {}

---@param class string
---@return table?
local function engineWeaponData(class)
    local cached = scriptCache[class]
    if cached ~= nil then return cached or nil end
    local raw = file.Read("scripts/" .. class .. ".txt", "GAME")
    if not raw then
        -- HL:S (Half-Life: Source) weapons are suffixed _hl1, but the script is just the
        -- base name so we read the base name directly from the game's mount to get the right
        -- script e.g. for weapon_357_hl1 we look for weapon_357.txt in the hl1 mount path
        local base, mount = string.match(class, "^(.+)_(%a%w*)$")
        if base then raw = file.Read("scripts/" .. base .. ".txt", mount) end
    end
    local kv
    if raw then
        -- try/catch to avoid crashing on weird files just in case
        local ok, parsed = pcall(util.KeyValuesToTable, raw)
        if ok and istable(parsed) then kv = parsed end
    end
    kv = kv or ENGINE_FALLBACK[class]
    scriptCache[class] = kv or false
    return kv
end

-- HL:S ammo types are suffixed HL1 where they conflict with HL2 ammo types e.g. Buckshot -> BuckshotHL1
---@param ammoType string?
---@return string?
local function hl1Ammo(ammoType)
    if ammoType and game.GetAmmoID(ammoType .. "HL1") >= 0 then return ammoType .. "HL1" end
    return ammoType
end

---@param ammoType string|number|nil
---@param clip number|string|nil
---@return string? type
---@return number clip
local function ammoPair(ammoType, clip)
    if ammoType == nil then return nil, 1 end
    ammoType = tostring(ammoType)
    if ammoType == "" or string.lower(ammoType) == "none" then return nil, 1 end
    local n = tonumber(ammoType)
    if n and n <= 0 then return nil, 1 end
    clip = tonumber(clip)
    return SpawnKit.NormalizeAmmoType(ammoType), (clip and clip > 0) and clip or 1
end

-- Ammo types that are considered internal and not given to the player, so we ignore them
local INTERNAL_AMMO = {
    -- For some reason the physgun declares the "Gravity" ammo type on it's secondary clip
    Gravity = true,
}

---@param class string
---@return string? primaryType
---@return number primaryClip
---@return string? secondaryType
---@return number secondaryClip
local function weaponAmmo(class)
    local swep = weapons.Get(class)
    if istable(swep) then
        local primary, secondary = swep.Primary, swep.Secondary
        local primaryType, primaryClip = ammoPair(istable(primary) and primary.Ammo or nil, istable(primary) and primary.ClipSize or nil)
        local secondaryType, secondaryClip = ammoPair(istable(secondary) and secondary.Ammo or nil, istable(secondary) and secondary.ClipSize or nil)
        return primaryType, primaryClip, secondaryType, secondaryClip
    end
    local kv = engineWeaponData(class)
    if not kv then return nil, 1, nil, 1 end
    local primaryType, primaryClip = ammoPair(kv.primary_ammo, kv.clip_size)
    local secondaryType, secondaryClip = ammoPair(kv.secondary_ammo, kv.clip2_size)
    if primaryType and INTERNAL_AMMO[primaryType] then primaryType = nil end
    if secondaryType and INTERNAL_AMMO[secondaryType] then secondaryType = nil end
    local entry = list.Get("Weapon")[class]
    if istable(entry) and entry.Category == "Half-Life: Source" then
        primaryType, secondaryType = hl1Ammo(primaryType), hl1Ammo(secondaryType)
    end
    return primaryType, primaryClip, secondaryType, secondaryClip
end

---@type table<string, table<string, number>>
local ammoTypesCache = {}

---@param class string
---@return table<string, number>
function SpawnKit.AmmoTypes(class)
    local cached = ammoTypesCache[class]
    if cached then return cached end
    local out = {}
    local primaryType, primaryClip, secondaryType, secondaryClip = weaponAmmo(class)
    if primaryType then out[primaryType] = primaryClip end
    if secondaryType and not out[secondaryType] then out[secondaryType] = secondaryClip end
    if weapons.GetStored(class) or engineWeaponData(class) then ammoTypesCache[class] = out end
    return out
end

-- Friendly name via GMod's own "<type>_ammo" language phrase or fallback to underscores replaced with spaces
---@param ammoType string
---@return string
function SpawnKit.AmmoName(ammoType)
    if language then
        local key = ammoType .. "_ammo"
        local name = language.GetPhrase(key)
        if name ~= key then return name end
    end
    return (string.gsub(ammoType, "_", " "))
end
