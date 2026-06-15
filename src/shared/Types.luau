--!strict

export type WeaponDef = {
	id: string,
	displayName: string,
	viewmodelName: string,
	damage: number,
	fireRate: number,
	range: number,
	magazineSize: number,
	reloadDuration: number,
}

export type HoldState = {
	kind: "Weapon" | "Prop" | "None",
	instance: Instance?,
	weaponId: string?,
}

export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

return {}
