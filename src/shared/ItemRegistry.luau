--!strict
-- Module: ItemRegistry
-- Classifies interactables and holds weapon definitions.

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local GeometryUtil = require(script.Parent.GeometryUtil)
local Types = require(script.Parent.Types)

type WeaponDef = Types.WeaponDef

local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "9mm Pistol",
		damage = 25,
		maxAmmo = 12,
		fireRateRps = 3,
		range = 200,
		spread = 0,
		reloadTime = 1.5,
		viewmodelName = "pistol_9mm",
	},
	rifle_ar = {
		weaponId = "rifle_ar",
		displayName = "Assault Rifle",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 10,
		range = 300,
		spread = 1.5,
		reloadTime = 2.2,
		viewmodelName = "rifle_ar",
	},
}

local ItemRegistry = {}

local function readItemType(instance: Instance): string?
	local itemType = instance:GetAttribute("ItemType")
	if typeof(itemType) == "string" then
		return itemType
	end
	return nil
end

local function isLegacyInteractable(instance: Instance): boolean
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return false
	end
	if CollectionService:HasTag(instance, Config.Drag.tag) then
		return true
	end
	return instance:GetAttribute(Config.Drag.attribute) == true
end

function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
	local itemType = readItemType(instance)
	if itemType == "Weapon" then
		return "Weapon"
	end
	if itemType == "Prop" then
		return "Prop"
	end
	if isLegacyInteractable(instance) then
		return "Prop"
	end
	return "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local weaponId = instance:GetAttribute("WeaponId")
	if typeof(weaponId) == "string" and WEAPON_DEFS[weaponId] ~= nil then
		return weaponId
	end
	if instance:IsA("Model") and WEAPON_DEFS[instance.Name] ~= nil then
		return instance.Name
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
	return WEAPON_DEFS[weaponId]
end

function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	local draggable = instance:GetAttribute("Draggable")
	if draggable == false then
		return false
	end
	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary then
		return false
	end
	if primary.Anchored then
		return false
	end
	if instance:GetAttribute(Config.Drag.heldByAttribute) ~= nil then
		return false
	end
	return true
end

function ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
	return WEAPON_DEFS
end

function ItemRegistry.resolveFromHit(hit: Instance?, workspaceRoot: Instance): Instance?
	local node: Instance? = hit
	while node and node ~= workspaceRoot do
		local kind = ItemRegistry.classify(node)
		if kind ~= "None" then
			return node
		end
		node = node.Parent
	end
	return nil
end

return ItemRegistry
