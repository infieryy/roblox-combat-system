local WeaponDefinitions = {
	rifle = {
		id = "rifle",
		displayName = "Rifle",
		damage = 20,
		range = 350,
		cooldown = 0.12,
		viewmodelName = "VM_Rifle",
		muzzleOffset = CFrame.new(0.6, -0.65, -1.65),
		dragInfluence = Vector3.new(0.0015, 0.0011, 0),
	},
	pistol = {
		id = "pistol",
		displayName = "Pistol",
		damage = 14,
		range = 220,
		cooldown = 0.2,
		viewmodelName = "VM_Pistol",
		muzzleOffset = CFrame.new(0.55, -0.7, -1.45),
		dragInfluence = Vector3.new(0.0012, 0.0009, 0),
	},
}

local function getWeapon(weaponId)
	return WeaponDefinitions[weaponId]
end

return {
	all = WeaponDefinitions,
	getWeapon = getWeapon,
}
