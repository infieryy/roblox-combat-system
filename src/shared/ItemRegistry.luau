--!strict
-- Module: shared/ItemRegistry
-- Classifies world items and holds the weapon definitions. The one place that
-- decides "is this a Weapon, a Prop, or nothing", so the server and client can
-- never disagree.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Types = require(script.Parent:WaitForChild("Types"))
local GeometryUtil = require(script.Parent:WaitForChild("GeometryUtil"))

type WeaponDef = Types.WeaponDef
type ItemKind = Types.ItemKind

local ItemRegistry = {}

-- Attribute keys read off Studio-authored instances.
local ATTR_ITEM_TYPE = "ItemType" -- "Weapon" | "Prop"
local ATTR_WEAPON_ID = "WeaponId"
local ATTR_DRAGGABLE = "Draggable"
local LEGACY_TAG = "Interactable" -- consensus CollectionService tag
local LEGACY_ATTR = "Interactable" -- consensus boolean attribute

-- Weapon catalogue. Add new guns here; `viewmodelName` is what the client
-- viewmodel builder keys off when constructing the on-screen model.
local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "9mm Pistol",
		damage = 24,
		maxAmmo = 12,
		fireRateRps = 7,
		range = 250,
		spread = 0.012,
		reloadTime = 1.4,
		viewmodelName = "Pistol",
	},
	rifle_556 = {
		weaponId = "rifle_556",
		displayName = "5.56 Rifle",
		damage = 18,
		maxAmmo = 30,
		fireRateRps = 11,
		range = 400,
		spread = 0.02,
		reloadTime = 2.2,
		viewmodelName = "Rifle",
	},
	shotgun_12g = {
		weaponId = "shotgun_12g",
		displayName = "12-Gauge",
		damage = 64,
		maxAmmo = 6,
		fireRateRps = 1.6,
		range = 90,
		spread = 0.06,
		reloadTime = 2.8,
		viewmodelName = "Shotgun",
	},
}

local function isModelOrPart(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("BasePart")
end

-- Classify a single instance (does not walk the tree — use `resolve` for that).
function ItemRegistry.classify(instance: Instance): ItemKind
	if not isModelOrPart(instance) then
		return "None"
	end
	local itemType = instance:GetAttribute(ATTR_ITEM_TYPE)
	if itemType == "Weapon" then
		return "Weapon"
	elseif itemType == "Prop" then
		return "Prop"
	end
	-- Backward-compat: consensus test props tagged/attributed "Interactable"
	-- keep working, treated as Props.
	if CollectionService:HasTag(instance, LEGACY_TAG) or instance:GetAttribute(LEGACY_ATTR) == true then
		return "Prop"
	end
	return "None"
end

-- Walk up from a raycast hit to the nearest classified Weapon/Prop.
function ItemRegistry.resolve(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= Workspace do
		if ItemRegistry.classify(node) ~= "None" then
			return node
		end
		node = node.Parent
	end
	return nil
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local id = instance:GetAttribute(ATTR_WEAPON_ID)
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
	return WEAPON_DEFS[weaponId]
end

function ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
	return WEAPON_DEFS
end

-- A prop is draggable if it classifies as a Prop, is not explicitly locked, has
-- a primary part, and that part is not anchored.
function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	if instance:GetAttribute(ATTR_DRAGGABLE) == false then
		return false
	end
	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary or primary.Anchored then
		return false
	end
	return true
end

return ItemRegistry
