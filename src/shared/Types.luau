--!strict
-- Module: Types
-- Shared type exports. Never has runtime logic — pure type declarations.
-- Import: local Types = require(path.to.Types)

export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number,    -- rounds per second (server enforced)
	range: number,          -- studs
	spread: number,         -- max deviation in degrees
	reloadTime: number,     -- seconds
	viewmodelName: string,  -- asset name under ReplicatedStorage.Assets.Viewmodels
	muzzleOffset: CFrame,   -- offset from camera CFrame to muzzle world position
	dragInfluence: Vector3, -- XYZ scale applied to mouse delta for viewmodel kick
}

-- Authoritative hold state carried by PlayerHoldState (server) and predicted
-- by client controllers after HoldStateChanged fires.
export type HoldState = {
	kind: "Weapon" | "Prop" | "None",
	instance: Instance?,
	weaponId: string?, -- populated only when kind == "Weapon"
}

-- The three instances that make up a server-built drag rig.
-- The server creates these and hands the references to the owning client via DragGranted.
export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

return {}
