--!strict
-- Module: ItemRegistry
-- Classifies interactable instances and holds weapon definitions.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

type WeaponDef = Types.WeaponDef
type ItemKind = Types.ItemKind

local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "9mm Pistol",
		damage = 25,
		maxAmmo = 12,
		fireRateRps = 6,
		range = 200,
		spread = 0.02,
		reloadTime = 1.8,
		viewmodelName = "pistol_9mm",
	},
	rifle_ar = {
		weaponId = "rifle_ar",
		displayName = "Assault Rifle",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 10,
		range = 300,
		spread = 0.035,
		reloadTime = 2.2,
		viewmodelName = "rifle_ar",
	},
}

local ItemRegistry = {}

local function isModelOrPart(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("BasePart")
end

local function isLegacyInteractable(instance: Instance): boolean
	if CollectionService:HasTag(instance, Config.Legacy.tag) then
		return true
	end
	return instance:GetAttribute(Config.Attributes.interactable) == true
end

function ItemRegistry.classify(instance: Instance): ItemKind
	if not isModelOrPart(instance) then
		return "None"
	end

	local itemType = instance:GetAttribute(Config.Attributes.itemType)
	if typeof(itemType) == "string" then
		if itemType == "Weapon" then
			return "Weapon"
		end
		if itemType == "Prop" then
			return "Prop"
		end
	end

	if isLegacyInteractable(instance) then
		return "Prop"
	end

	return "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local weaponId = instance:GetAttribute(Config.Attributes.weaponId)
	if typeof(weaponId) == "string" and weaponId ~= "" then
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

	local draggable = instance:GetAttribute(Config.Attributes.draggable)
	if draggable == false then
		return false
	end

	local primary = if instance:IsA("BasePart")
		then instance
		elseif instance:IsA("Model") then instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
		else nil

	if primary and primary:IsA("BasePart") and primary.Anchored then
		return false
	end

	return true
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
