--!strict
-- Module: shared/Types
-- Cross-module data shapes. Every module that exchanges these structures
-- requires this single copy so the contracts in BLUEPRINT.md §12 stay frozen.

export type ItemKind = "Weapon" | "Prop" | "None"

-- Static, designer-authored description of a weapon (BLUEPRINT.md §12).
export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number, -- rounds per second the server will allow
	range: number, -- hitscan ray length (studs)
	spread: number, -- max cone half-angle in degrees used for client visuals
	reloadTime: number, -- seconds
	viewmodelName: string, -- key into the client viewmodel asset/builder
}

-- Server-authoritative "what is this player holding" (one item at a time).
export type HoldState = {
	kind: ItemKind,
	instance: Instance?,
	weaponId: string?,
}

-- The constraint rig used to physically carry a dragged prop. Built by the
-- server, steered by the owning client.
export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

return {}
