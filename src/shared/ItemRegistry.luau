--!strict
-- Module: shared/ItemRegistry
-- Classifies interactables and holds the weapon definitions (BLUEPRINT.md §9.2).
-- The one place that decides "is this a Weapon, a Prop, or nothing", shared by
-- the server (Drag/Equip/Weapon services) and the client (InteractionController).

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)
local GeometryUtil = require(script.Parent.GeometryUtil)
local Types = require(script.Parent.Types)

type WeaponDef = Types.WeaponDef
type ItemKind = Types.ItemKind

local ItemRegistry = {}

-- Designer-authored weapon definitions. A weapon instance points at one of
-- these via its `WeaponId` attribute. Values are tunable; the keys are the
-- frozen registry IDs referenced over the network.
local WEAPON_DEFS: { [string]: WeaponDef } = {
	pistol_9mm = {
		weaponId = "pistol_9mm",
		displayName = "9mm Pistol",
		damage = 24,
		maxAmmo = 12,
		fireRateRps = 7,
		range = 300,
		spread = 0.6,
		reloadTime = 1.4,
		viewmodelName = "Pistol",
	},
	rifle_556 = {
		weaponId = "rifle_556",
		displayName = "5.56 Rifle",
		damage = 32,
		maxAmmo = 30,
		fireRateRps = 11,
		range = 500,
		spread = 1.2,
		reloadTime = 2.2,
		viewmodelName = "Rifle",
	},
}

local function isModelOrPart(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("BasePart")
end

-- "Weapon" if ItemType attr == "Weapon"; "Prop" if ItemType == "Prop" OR
-- (backward-compat) the CollectionService tag "Interactable" / attribute
-- Interactable == true; else "None".
function ItemRegistry.classify(instance: Instance): ItemKind
	if not isModelOrPart(instance) then
		return "None"
	end

	local itemType = instance:GetAttribute(Config.Attributes.itemType)
	if itemType == "Weapon" then
		return "Weapon"
	elseif itemType == "Prop" then
		return "Prop"
	end

	-- Backward-compat: legacy props are tagged/attributed "Interactable".
	if CollectionService:HasTag(instance, Config.InteractTag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.Attributes.interactable) == true then
		return "Prop"
	end

	return "None"
end

-- Walk up from a hit instance to the nearest classified Weapon/Prop, returning
-- both the instance and its kind. Ported from the consensus resolveInteractable
-- but type-aware.
function ItemRegistry.resolve(hit: Instance?): (Instance?, ItemKind)
	local node: Instance? = hit
	while node and node ~= workspace do
		local kind = ItemRegistry.classify(node)
		if kind ~= "None" then
			return node, kind
		end
		node = node.Parent
	end
	return nil, "None"
end

function ItemRegistry.getWeaponId(instance: Instance): string?
	local id = instance:GetAttribute(Config.Attributes.weaponId)
	if typeof(id) == "string" and WEAPON_DEFS[id] ~= nil then
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

-- A prop that may actually be grabbed: classified Prop, has a movable primary
-- part, and is not explicitly locked via the Draggable attribute.
function ItemRegistry.isDraggable(instance: Instance): boolean
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end
	if instance:GetAttribute(Config.Attributes.draggable) == false then
		return false
	end
	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary or primary.Anchored then
		return false
	end
	return true
end

return ItemRegistry
