--!strict
-- Module: ItemRegistry
-- Classifies interactable instances and holds weapon definitions.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local GeometryUtil = require(script.Parent.GeometryUtil)
local Types = require(script.Parent.Types)

type WeaponDef = Types.WeaponDef
type ItemKind = "Weapon" | "Prop" | "None"

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
		viewmodelName = "PistolViewmodel",
	},
	rifle_556 = {
		weaponId = "rifle_556",
		displayName = "5.56 Rifle",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 10,
		range = 300,
		spread = 1.5,
		reloadTime = 2.2,
		viewmodelName = "RifleViewmodel",
	},
}

local ItemRegistry = {}

function ItemRegistry.classify(instance: Instance): ItemKind
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return "None"
	end

	local itemType = instance:GetAttribute("ItemType")
	if typeof(itemType) == "string" then
		if itemType == "Weapon" then
			return "Weapon"
		end
		if itemType == "Prop" then
			return "Prop"
		end
	end

	if CollectionService:HasTag(instance, Config.Drag.tag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.Drag.attribute) == true then
		return "Prop"
	end

	return "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local weaponId = instance:GetAttribute("WeaponId")
	if typeof(weaponId) == "string" and WEAPON_DEFS[weaponId] then
		return weaponId
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
	return WEAPON_DEFS[weaponId]
end

function ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
	return WEAPON_DEFS
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
	if not primary or primary.Anchored then
		return false
	end
	if instance:GetAttribute(Config.Drag.heldByAttribute) ~= nil then
		return false
	end
	return true
end

function ItemRegistry.resolveInteractable(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= Workspace do
		if ItemRegistry.classify(node) ~= "None" then
			return node
		end
		node = node.Parent
	end
	return nil
end

return ItemRegistry
