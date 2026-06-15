--!strict
--[[
	WeaponConfig
	------------
	Single source of truth for the combat / weapon layer, mirroring the role
	`Config` plays for the pickup system. Both the client and the server require
	this module so the viewmodel, the input controller and the authoritative
	damage logic all agree on the same numbers (no "magic values" buried in the
	controllers, and nothing the server validates can drift from what the client
	predicts).

	A weapon is a plain data definition. Geometry is described, not pre-built, so
	the viewmodel can be constructed entirely from this table at runtime — there
	are no Studio-authored Tool/Model dependencies, which keeps the system fully
	self-contained and version-controllable.
]]

export type Vector3Like = { x: number, y: number, z: number }

-- A single visible piece of a weapon's viewmodel. Offsets are expressed in the
-- viewmodel's local space (relative to the camera), so they are resolution- and
-- field-of-view independent.
export type ViewmodelPart = {
	Name: string,
	Size: Vector3Like,
	-- Local offset from the viewmodel root, in studs.
	Offset: Vector3Like,
	-- Local rotation from the viewmodel root, in degrees (X, Y, Z / pitch, yaw, roll).
	Rotation: Vector3Like,
	Color: { r: number, g: number, b: number },
	Material: Enum.Material,
	-- The single part that the muzzle flash / barrel ray originates from. Exactly
	-- one part per weapon should set this true.
	IsMuzzle: boolean?,
}

export type WeaponDefinition = {
	DisplayName: string,
	-- Slot the weapon binds to (1-9). Mapped to the matching number key.
	Slot: number,

	-- Combat tuning
	Damage: number,
	HeadshotMultiplier: number,
	Range: number, -- studs
	-- Rounds per minute -> the service converts this to a minimum interval.
	FireRate: number,
	-- false = single shot per click, true = hold to keep firing.
	Automatic: boolean,
	-- How many pellets per shot (1 for a rifle, >1 for a shotgun-style spread).
	Pellets: number,
	-- Cone half-angle for pellet spread, in degrees (0 = perfectly accurate).
	SpreadDegrees: number,

	-- Ammo
	MagazineSize: number,
	ReserveAmmo: number,
	ReloadTime: number,

	-- First-person feel
	-- Local-space resting offset of the whole viewmodel from the camera.
	HoldOffset: Vector3Like,
	-- Idle bob amplitude/speed and movement sway scaling.
	BobAmplitude: number,
	BobSpeed: number,
	SwayAmount: number,
	-- How snappily the viewmodel follows the camera (higher = stiffer).
	FollowResponsiveness: number,

	Parts: { ViewmodelPart },
}

export type WeaponConfigType = {
	-- Reuse the pickup system's collision groups so weapon rays never hit the
	-- shooter's own character or a held object by accident.
	IgnoreCollisionGroups: { string },

	-- Default key codes (as strings, resolved to Enum.KeyCode on the client).
	ReloadKey: string,
	HolsterKey: string,

	-- Networking guard rails (anti-exploit). The server rejects fire requests
	-- that arrive faster than the weapon's fire rate minus this slack, or that
	-- claim a hit further than the weapon's range plus this slack.
	FireRateTolerance: number, -- seconds of leeway for latency
	RangeTolerance: number, -- studs of leeway for latency

	Weapons: { [string]: WeaponDefinition },

	-- Helpers (defined below).
	fireInterval: (weapon: WeaponDefinition) -> number,
	get: (name: string) -> WeaponDefinition?,
	weaponForSlot: (slot: number) -> string?,
}

local WeaponConfig: WeaponConfigType = {
	IgnoreCollisionGroups = { "PickupCharacters", "PickupHeldObjects" },

	ReloadKey = "R",
	HolsterKey = "H",

	FireRateTolerance = 0.03,
	RangeTolerance = 6,

	Weapons = {
		--------------------------------------------------------------------
		Pistol = {
			DisplayName = "Pistol",
			Slot = 1,

			Damage = 18,
			HeadshotMultiplier = 2.0,
			Range = 250,
			FireRate = 360,
			Automatic = false,
			Pellets = 1,
			SpreadDegrees = 0.6,

			MagazineSize = 12,
			ReserveAmmo = 60,
			ReloadTime = 1.1,

			HoldOffset = { x = 1.1, y = -1.3, z = -2.0 },
			BobAmplitude = 0.06,
			BobSpeed = 9,
			SwayAmount = 0.10,
			FollowResponsiveness = 14,

			Parts = {
				{
					Name = "Grip",
					Size = { x = 0.32, y = 0.7, z = 0.34 },
					Offset = { x = 0, y = -0.32, z = 0.18 },
					Rotation = { x = -12, y = 0, z = 0 },
					Color = { r = 35, g = 35, b = 40 },
					Material = Enum.Material.Metal,
				},
				{
					Name = "Slide",
					Size = { x = 0.34, y = 0.36, z = 1.3 },
					Offset = { x = 0, y = 0.06, z = -0.35 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 55, g = 58, b = 64 },
					Material = Enum.Material.Metal,
				},
				{
					Name = "Barrel",
					Size = { x = 0.16, y = 0.16, z = 0.5 },
					Offset = { x = 0, y = 0.06, z = -1.05 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 20, g = 20, b = 22 },
					Material = Enum.Material.Metal,
					IsMuzzle = true,
				},
			},
		},

		--------------------------------------------------------------------
		Rifle = {
			DisplayName = "Rifle",
			Slot = 2,

			Damage = 26,
			HeadshotMultiplier = 1.8,
			Range = 600,
			FireRate = 660,
			Automatic = true,
			Pellets = 1,
			SpreadDegrees = 1.2,

			MagazineSize = 30,
			ReserveAmmo = 150,
			ReloadTime = 1.8,

			HoldOffset = { x = 1.0, y = -1.25, z = -2.3 },
			BobAmplitude = 0.05,
			BobSpeed = 8,
			SwayAmount = 0.08,
			FollowResponsiveness = 12,

			Parts = {
				{
					Name = "Stock",
					Size = { x = 0.3, y = 0.5, z = 0.9 },
					Offset = { x = 0, y = -0.1, z = 0.7 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 40, g = 30, b = 24 },
					Material = Enum.Material.Wood,
				},
				{
					Name = "Body",
					Size = { x = 0.34, y = 0.42, z = 1.9 },
					Offset = { x = 0, y = 0, z = -0.5 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 45, g = 47, b = 52 },
					Material = Enum.Material.Metal,
				},
				{
					Name = "Magazine",
					Size = { x = 0.22, y = 0.6, z = 0.34 },
					Offset = { x = 0, y = -0.42, z = -0.35 },
					Rotation = { x = -6, y = 0, z = 0 },
					Color = { r = 28, g = 28, b = 30 },
					Material = Enum.Material.Metal,
				},
				{
					Name = "Barrel",
					Size = { x = 0.16, y = 0.16, z = 1.0 },
					Offset = { x = 0, y = 0.04, z = -1.9 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 20, g = 20, b = 22 },
					Material = Enum.Material.Metal,
					IsMuzzle = true,
				},
			},
		},

		--------------------------------------------------------------------
		Shotgun = {
			DisplayName = "Shotgun",
			Slot = 3,

			Damage = 11, -- per pellet
			HeadshotMultiplier = 1.5,
			Range = 120,
			FireRate = 80,
			Automatic = false,
			Pellets = 8,
			SpreadDegrees = 5.5,

			MagazineSize = 6,
			ReserveAmmo = 36,
			ReloadTime = 2.4,

			HoldOffset = { x = 1.05, y = -1.3, z = -2.4 },
			BobAmplitude = 0.07,
			BobSpeed = 7,
			SwayAmount = 0.12,
			FollowResponsiveness = 11,

			Parts = {
				{
					Name = "Stock",
					Size = { x = 0.32, y = 0.52, z = 1.0 },
					Offset = { x = 0, y = -0.12, z = 0.8 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 38, g = 26, b = 20 },
					Material = Enum.Material.Wood,
				},
				{
					Name = "Receiver",
					Size = { x = 0.36, y = 0.44, z = 1.4 },
					Offset = { x = 0, y = 0, z = -0.2 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 50, g = 52, b = 58 },
					Material = Enum.Material.Metal,
				},
				{
					Name = "Barrel",
					Size = { x = 0.22, y = 0.22, z = 1.6 },
					Offset = { x = 0, y = 0.06, z = -1.7 },
					Rotation = { x = 0, y = 0, z = 0 },
					Color = { r = 22, g = 22, b = 24 },
					Material = Enum.Material.Metal,
					IsMuzzle = true,
				},
			},
		},
	},
}

-- Convenience: minimum seconds between shots for a weapon (rounds per minute).
function WeaponConfig.fireInterval(weapon: WeaponDefinition): number
	if weapon.FireRate <= 0 then
		return math.huge
	end
	return 60 / weapon.FireRate
end

-- Convenience: resolve a weapon name -> definition (nil if unknown).
function WeaponConfig.get(name: string): WeaponDefinition?
	return WeaponConfig.Weapons[name]
end

-- Convenience: map a 1-9 slot to its weapon name (nil if nothing is bound).
function WeaponConfig.weaponForSlot(slot: number): string?
	for name, def in WeaponConfig.Weapons do
		if def.Slot == slot then
			return name
		end
	end
	return nil
end

return WeaponConfig
