--!strict
-- Module: ItemRegistry
-- Classifies instances as "Weapon", "Prop", or "None" and houses weapon definitions.
-- Backward-compatible: instances tagged "Interactable" or with attribute Interactable=true
-- are classified as "Prop" (mirrors the consensus build's detection logic).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

type WeaponDef = Types.WeaponDef

-- -------------------------------------------------------------------------
-- Weapon registry (ported from dbc1 WeaponDefinitions, expanded to match Types.WeaponDef)
-- -------------------------------------------------------------------------

local WEAPON_REGISTRY: { [string]: WeaponDef } = {
	rifle = {
		weaponId = "rifle",
		displayName = "Rifle",
		damage = 20,
		maxAmmo = 30,
		fireRateRps = 1 / 0.12,           -- ~8.3 rounds per second
		range = 350,
		spread = 1.5,
		reloadTime = 2.2,
		viewmodelName = "VM_Rifle",
		muzzleOffset = CFrame.new(0.6, -0.65, -1.65),
		dragInfluence = Vector3.new(0.0015, 0.0011, 0),
	},
	pistol = {
		weaponId = "pistol",
		displayName = "Pistol",
		damage = 14,
		maxAmmo = 15,
		fireRateRps = 1 / 0.2,            -- 5 rounds per second
		range = 220,
		spread = 2.5,
		reloadTime = 1.6,
		viewmodelName = "VM_Pistol",
		muzzleOffset = CFrame.new(0.55, -0.7, -1.45),
		dragInfluence = Vector3.new(0.0012, 0.0009, 0),
	},
}

-- -------------------------------------------------------------------------
-- Classification
-- -------------------------------------------------------------------------

local ItemRegistry = {}

-- Returns "Weapon", "Prop", or "None".
-- Priority: explicit ItemType attribute → legacy Interactable tag/attribute → None.
function ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return "None"
	end

	local itemType = instance:GetAttribute(Config.Detection.itemTypeAttribute)
	if itemType == "Weapon" then
		return "Weapon"
	end
	if itemType == "Prop" then
		return "Prop"
	end

	-- Backward-compat: legacy Interactable tag/attribute → treat as Prop
	if CollectionService:HasTag(instance, Config.Detection.tag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.Detection.attribute) == true then
		return "Prop"
	end

	return "None"
end

-- A Prop is draggable unless explicitly locked with Draggable=false.
function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	-- Anchored props are not draggable (server also checks this).
	local primary = instance:IsA("BasePart") and instance or (instance:IsA("Model") and instance.PrimaryPart)
	if primary and (primary :: BasePart).Anchored then
		return false
	end
	-- Opt-out attribute
	local draggable = instance:GetAttribute(Config.Detection.draggableAttribute)
	if draggable == false then
		return false
	end
	return true
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local id = instance:GetAttribute(Config.Detection.weaponIdAttribute)
	if typeof(id) == "string" then
		return id
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
	return WEAPON_REGISTRY[weaponId]
end

function ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
	return WEAPON_REGISTRY
end

return ItemRegistry
