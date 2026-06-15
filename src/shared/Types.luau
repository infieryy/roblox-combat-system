--!strict
-- Module: Types
-- Shared type definitions for the item & combat system.

export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number,
	range: number,
	spread: number,
	reloadTime: number,
	viewmodelName: string,
}

export type HoldKind = "Weapon" | "Prop" | "None"

export type HoldState = {
	kind: HoldKind,
	instance: Instance?,
	weaponId: string?,
}

export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

return {}
