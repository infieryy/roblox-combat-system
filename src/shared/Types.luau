--!strict
-- Module: shared/Types
-- Cross-module type definitions. Required by both server and client so the
-- frozen contract shapes (§8/§12 of the blueprint) live in exactly one place.

export type ItemKind = "Weapon" | "Prop" | "None"

-- A weapon definition (registry entry). All gameplay numbers are server-trusted.
export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number, -- rounds per second the server will allow
	range: number, -- max hitscan range in studs
	spread: number, -- cosmetic client spread (radians); server uses plausibility cone
	reloadTime: number, -- seconds
	viewmodelName: string, -- key the client viewmodel builder keys off
}

-- The single source of truth for "what is this player holding right now".
export type HoldState = {
	kind: ItemKind,
	instance: Instance?,
	weaponId: string?,
}

-- The constraint rig the server builds for a dragged prop and hands to the
-- owning client to steer.
export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

return {}
