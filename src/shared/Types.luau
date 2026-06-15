--!strict
-- Module: Types
-- Cross-module type definitions shared by every server and client module.
-- Require this in any module that needs WeaponDef, HoldState, or HoldRig.
--
-- Usage:
--   local Types = require(game:GetService("ReplicatedStorage").Shared.Types)
--   local def: Types.WeaponDef = ...

export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number,
	range: number,
	spread: number,       -- degrees of cone spread
	reloadTime: number,   -- seconds
	viewmodelName: string, -- name of model inside ReplicatedStorage.ViewmodelAssets
}

-- Authoritative one-item hold state (server owns this; client mirrors it via HoldStateChanged).
export type HoldKind = "Weapon" | "Prop" | "None"

export type HoldState = {
	kind: HoldKind,
	instance: Instance?,
	weaponId: string?,
}

-- The three-piece constraint rig created by DragService on the server.
-- The server sends refs to the owning client via DragGranted so the client
-- can steer the goals locally each frame.
export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

-- Per-player drag session record (internal to DragService).
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
