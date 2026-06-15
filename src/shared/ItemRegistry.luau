--!strict

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent:WaitForChild("Config"))
local _Types = require(script.Parent:WaitForChild("Types"))

local WeaponDefinitions: { [string]: _Types.WeaponDef } = {
	pistol_9mm = {
		id = "pistol_9mm",
		displayName = "9mm Pistol",
		viewmodelName = "VM_Pistol9mm",
		damage = 20,
		fireRate = 4,
		range = 350,
		magazineSize = 12,
		reloadDuration = 1.25,
	},
	carbine_556 = {
		id = "carbine_556",
		displayName = "5.56 Carbine",
		viewmodelName = "VM_Carbine556",
		damage = 28,
		fireRate = 8,
		range = 500,
		magazineSize = 30,
		reloadDuration = 1.8,
	},
}

local function classifyNode(instance: Instance): "Weapon" | "Prop" | "None"
	local raw = instance:GetAttribute(Config.Interaction.itemTypeAttribute)
	if raw == "Weapon" then
		return "Weapon"
	end
	if raw == "Prop" then
		return "Prop"
	end
	if CollectionService:HasTag(instance, Config.Interaction.interactTag) then
		return "Prop"
	end
	if instance:GetAttribute(Config.Interaction.interactAttribute) == true then
		return "Prop"
	end
	return "None"
end

local ItemRegistry = {}

function ItemRegistry.classify(instance: Instance?): "Weapon" | "Prop" | "None"
	local cursor = instance
	while cursor and cursor ~= workspace do
		local kind = classifyNode(cursor)
		if kind ~= "None" then
			return kind
		end
		cursor = cursor.Parent
	end
	return "None"
end

function ItemRegistry.resolveItemRoot(instance: Instance?): Instance?
	local cursor = instance
	while cursor and cursor ~= workspace do
		if classifyNode(cursor) ~= "None" then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

function ItemRegistry.getWeaponId(instance: Instance?): string?
	local cursor = instance
	while cursor and cursor ~= workspace do
		local value = cursor:GetAttribute(Config.Interaction.weaponIdAttribute)
		if typeof(value) == "string" and value ~= "" then
			return value
		end
		cursor = cursor.Parent
	end
	return nil
end

function ItemRegistry.getWeaponDef(weaponId: string): _Types.WeaponDef?
	return WeaponDefinitions[weaponId]
end

function ItemRegistry.getAllWeaponDefs(): { [string]: _Types.WeaponDef }
	return WeaponDefinitions
end

function ItemRegistry.isDraggable(instance: Instance?): boolean
	if not instance then
		return false
	end
	if ItemRegistry.classify(instance) ~= "Prop" then
		return false
	end

	local flag = instance:GetAttribute(Config.Interaction.draggableAttribute)
	if flag == false then
		return false
	end

	if instance:IsA("BasePart") then
		return not instance.Anchored
	end
	if instance:IsA("Model") then
		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("BasePart") and not descendant.Anchored then
				return true
			end
		end
	end
	return false
end

return ItemRegistry
