--!strict
-- Module: Shared type contracts for the item system.

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

export type DragSession = {
	object: Instance,
	primary: BasePart,
	rig: HoldRig,
	welds: { WeldConstraint },
	anchoredSnapshot: { [BasePart]: boolean },
	collisionSnapshot: { [BasePart]: string },
	connections: { RBXScriptConnection },
	boundingRadius: number,
	breachTime: number,
}

return {}
