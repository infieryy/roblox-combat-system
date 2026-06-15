--!strict
-- Module: Item classification and weapon definition registry.

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local GeometryUtil = require(script.Parent.GeometryUtil)
local Types = require(script.Parent.Types)
type WeaponDef = Types.WeaponDef

local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "Pistol 9mm",
		damage = 24,
		maxAmmo = 12,
		fireRateRps = 5.5,
		range = 350,
		spread = 0.003,
		reloadTime = 1.35,
		viewmodelName = "VM_Pistol9mm",
	},
	rifle_556 = {
		weaponId = "rifle_556",
		displayName = "Rifle 5.56",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 9,
		range = 550,
		spread = 0.0045,
		reloadTime = 1.9,
		viewmodelName = "VM_Rifle556",
	},
}

local ItemRegistry = {}

local function isInteractableLegacy(instance: Instance): boolean
	return CollectionService:HasTag(instance, Config.Drag.tag) or instance:GetAttribute(Config.Drag.attribute) == true
end

function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return "None"
	end

	local explicitType = instance:GetAttribute("ItemType")
	if explicitType == "Weapon" then
		return "Weapon"
	elseif explicitType == "Prop" then
		return "Prop"
	end

	if isInteractableLegacy(instance) then
		return "Prop"
	end

	return "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local value = instance:GetAttribute("WeaponId")
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
	return WEAPON_DEFS[weaponId]
end

function ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
	return table.clone(WEAPON_DEFS)
end

function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end

	local draggableAttr = instance:GetAttribute("Draggable")
	if draggableAttr == false then
		return false
	end

	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary then
		return false
	end

	if primary.Anchored then
		return false
	end

	if primary.Locked then
		return false
	end

	return true
end

return ItemRegistry
