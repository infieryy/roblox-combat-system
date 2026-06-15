--!strict
-- Module: shared/ItemRegistry.luau

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)

type WeaponDef = Types.WeaponDef

local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "9mm Pistol",
		damage = 25,
		maxAmmo = 12,
		fireRateRps = 3,
		range = 300,
		spread = 0.02,
		reloadTime = 2,
		viewmodelName = "pistol_9mm",
	},
	rifle_556 = {
		weaponId = "rifle_556",
		displayName = "5.56 Rifle",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 10,
		range = 400,
		spread = 0.035,
		reloadTime = 2.5,
		viewmodelName = "rifle_556",
	},
}

local ItemRegistry = {}

local function isLegacyProp(instance: Instance): boolean
	if CollectionService:HasTag(instance, Config.LegacyTag) then
		return true
	end
	return instance:GetAttribute(Config.LegacyAttribute) == true
end

function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
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

	if isLegacyProp(instance) then
		return "Prop"
	end

	return "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local weaponId = instance:GetAttribute("WeaponId")
	if typeof(weaponId) == "string" and weaponId ~= "" then
		return weaponId
	end
	if instance:IsA("Model") and instance.Name ~= "" then
		if WEAPON_DEFS[instance.Name] then
			return instance.Name
		end
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
	local primary = if instance:IsA("BasePart") then instance else instance:FindFirstChildWhichIsA("BasePart", true)
	if primary and primary:IsA("BasePart") and primary.Anchored then
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
