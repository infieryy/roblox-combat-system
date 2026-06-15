--!strict
--[[
	ItemRegistry  (shared/ItemRegistry.luau → ReplicatedStorage.Shared.ItemRegistry)
	----------------------------------------------------------------------------------
	Classifies every interactable item and holds the authoritative weapon definitions.

	Classification rules (checked in order):
	  1. ItemType attribute == "Weapon"  →  "Weapon"
	  2. ItemType attribute == "Prop"    →  "Prop"
	  3. Legacy: CollectionService tag "Interactable" or attribute Interactable == true
	             →  "Prop"   (backward-compat — existing test props keep working)
	  4. Everything else                 →  "None"

	Weapon definitions are stored here in WEAPON_DEFS. Add your weapons to that
	table. The rest of the system reads them by weaponId string key.
]]

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local Types  = require(script.Parent.Types)

-- ─────────────────────────────────────────────────────────────────────────────
-- Weapon definitions
-- ─────────────────────────────────────────────────────────────────────────────

-- Add weapon entries here. The viewmodelName must match a Model name in
-- ReplicatedStorage (or wherever your Studio place stores viewmodel templates).
local WEAPON_DEFS: { [string]: Types.WeaponDef } = {
	pistol_9mm = {
		weaponId     = "pistol_9mm",
		displayName  = "9mm Pistol",
		damage       = 25,
		maxAmmo      = 12,
		fireRateRps  = 3,      -- 3 rounds per second
		range        = 300,    -- studs
		spread       = 1.5,    -- degrees
		reloadTime   = 1.8,    -- seconds
		viewmodelName = "VM_Pistol",
	},
	smg_9mm = {
		weaponId     = "smg_9mm",
		displayName  = "9mm SMG",
		damage       = 18,
		maxAmmo      = 30,
		fireRateRps  = 8,
		range        = 200,
		spread       = 3.0,
		reloadTime   = 2.2,
		viewmodelName = "VM_SMG",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local ItemRegistry = {}

-- Returns "Weapon", "Prop", or "None" for the given instance.
function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
	local itemType = instance:GetAttribute(Config.ItemTypeAttribute)
	if itemType == "Weapon" then
		return "Weapon"
	elseif itemType == "Prop" then
		return "Prop"
	end
	-- Legacy backward-compat path: tag OR bool attribute → Prop.
	if CollectionService:HasTag(instance, Config.LegacyTag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.LegacyAttribute) == true then
		return "Prop"
	end
	return "None"
end

-- Returns the WeaponId attribute from the instance, or nil.
function ItemRegistry.getWeaponId(instance: Instance): string?
	local id = instance:GetAttribute(Config.WeaponIdAttribute)
	if typeof(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

-- Returns the WeaponDef for a weapon ID, or nil if unknown.
function ItemRegistry.getWeaponDef(weaponId: string): Types.WeaponDef?
	return WEAPON_DEFS[weaponId]
end

-- Returns all weapon definitions.
function ItemRegistry.getAllWeaponDefs(): { [string]: Types.WeaponDef }
	return WEAPON_DEFS
end

-- Returns true when a prop can currently be dragged.
-- A prop is draggable when:
--   • it is classified as a Prop
--   • the Draggable attribute is absent OR explicitly true
--   • it is not currently held by another player
function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	local draggable = instance:GetAttribute(Config.DraggableAttribute)
	if draggable == false then
		-- Explicitly locked.
		return false
	end
	-- Already held by someone?
	if instance:GetAttribute(Config.HeldByAttribute) ~= nil then
		return false
	end
	return true
end

return ItemRegistry
