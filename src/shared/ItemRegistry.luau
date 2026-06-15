--!strict
-- Module: ItemRegistry
-- Classifies world instances as Weapon, Prop, or None.
-- Holds the authoritative weapon-definition table.
-- Runs on both server and client (lives in ReplicatedStorage.Shared).
--
-- Item classification rules (in priority order):
--   1. ItemType attribute == "Weapon"  → "Weapon"
--   2. ItemType attribute == "Prop"    → "Prop"
--   3. CollectionService tag "Interactable" OR attribute Interactable==true → "Prop" (legacy compat)
--   4. Otherwise                       → "None"
--
-- Authoring a weapon:  Set attribute ItemType="Weapon" and WeaponId="<id>" on the Model.
-- Authoring a prop:    Set attribute ItemType="Prop" (or legacy Interactable tag/attribute).
-- Locking a prop:      Set attribute Draggable=false.

local CollectionService = game:GetService("CollectionService")
local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)

-- -------------------------------------------------------------------------
-- Weapon definition table.
-- Add entries here as you build out the game's weapon roster.
-- Each key is the weaponId string stamped on the in-world weapon model via
-- the WeaponId attribute.
-- -------------------------------------------------------------------------
local WEAPON_DEFS: { [string]: Types.WeaponDef } = {
	pistol_9mm = {
		weaponId     = "pistol_9mm",
		displayName  = "Pistol",
		damage       = 25,
		maxAmmo      = 12,
		fireRateRps  = 3,
		range        = 150,
		spread       = 1.5,
		reloadTime   = 1.8,
		viewmodelName = "Viewmodel_Pistol",
	},
	smg_uzi = {
		weaponId     = "smg_uzi",
		displayName  = "SMG",
		damage       = 18,
		maxAmmo      = 30,
		fireRateRps  = 10,
		range        = 120,
		spread       = 3.0,
		reloadTime   = 2.2,
		viewmodelName = "Viewmodel_SMG",
	},
}

local ItemRegistry = {}

-- Classify an instance as "Weapon", "Prop", or "None".
-- Never errors; returns "None" for anything unrecognised.
function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return "None"
	end

	local itemType = instance:GetAttribute("ItemType")
	if itemType == "Weapon" then
		return "Weapon"
	end
	if itemType == "Prop" then
		return "Prop"
	end

	-- Legacy backward-compat: CollectionService tag OR boolean attribute.
	if CollectionService:HasTag(instance, Config.Drag.Tag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.Drag.Attribute) == true then
		return "Prop"
	end

	return "None"
end

-- Return the WeaponId attribute value, or nil if not present.
function ItemRegistry.getWeaponId(instance: Instance): string?
	local id = instance:GetAttribute("WeaponId")
	if typeof(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

-- Retrieve a weapon definition by ID; returns nil for unknown IDs.
function ItemRegistry.getWeaponDef(weaponId: string): Types.WeaponDef?
	return WEAPON_DEFS[weaponId]
end

-- True if the instance is a Prop and the Draggable attribute is not explicitly false.
-- Does NOT check anchored state here — that is a server-side validation concern.
function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	local draggable = instance:GetAttribute("Draggable")
	if draggable == false then
		return false
	end
	return true
end

-- All registered weapon definitions. Used for UI or preloading.
function ItemRegistry.getAllWeaponDefs(): { [string]: Types.WeaponDef }
	return WEAPON_DEFS
end

return ItemRegistry
