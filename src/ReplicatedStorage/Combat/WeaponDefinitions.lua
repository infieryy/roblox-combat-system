local WeaponDefinitions = {}

export type WeaponDefinition = {
	id: string,
	displayName: string,
	fireRate: number,
	magazineSize: number,
	reloadDuration: number,
	equipDuration: number,
	canAutoFire: boolean,
	damage: number,
	range: number,
	dragTag: string,
	viewmodelName: string,
	viewmodelOffset: CFrame,
	viewmodelSwayScale: number,
}

WeaponDefinitions.ById = {
	carbine = {
		id = "carbine",
		displayName = "XR-12 Carbine",
		fireRate = 8,
		magazineSize = 30,
		reloadDuration = 1.8,
		equipDuration = 0.25,
		canAutoFire = true,
		damage = 18,
		range = 420,
		dragTag = "DraggableWeapon",
		viewmodelName = "CarbineViewmodel",
		viewmodelOffset = CFrame.new(0.65, -0.95, -1.45),
		viewmodelSwayScale = 1,
	},
	sidearm = {
		id = "sidearm",
		displayName = "M-9 Sidearm",
		fireRate = 4.5,
		magazineSize = 14,
		reloadDuration = 1.2,
		equipDuration = 0.2,
		canAutoFire = false,
		damage = 26,
		range = 300,
		dragTag = "DraggableWeapon",
		viewmodelName = "SidearmViewmodel",
		viewmodelOffset = CFrame.new(0.62, -1.02, -1.28),
		viewmodelSwayScale = 0.8,
	},
	blade = {
		id = "blade",
		displayName = "Carbon Blade",
		fireRate = 1.8,
		magazineSize = 1,
		reloadDuration = 0,
		equipDuration = 0.18,
		canAutoFire = false,
		damage = 45,
		range = 12,
		dragTag = "DraggableWeapon",
		viewmodelName = "BladeViewmodel",
		viewmodelOffset = CFrame.new(0.55, -1.05, -0.95),
		viewmodelSwayScale = 0.65,
	},
} :: { [string]: WeaponDefinition }

function WeaponDefinitions.get(weaponId: string): WeaponDefinition
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		error(("Unknown weapon id '%s'"):format(weaponId))
	end

	return definition
end

function WeaponDefinitions.exists(weaponId: string): boolean
	return WeaponDefinitions.ById[weaponId] ~= nil
end

return WeaponDefinitions
