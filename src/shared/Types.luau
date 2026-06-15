--!strict
--[[
	Types  (shared/Types.luau → ReplicatedStorage.Shared.Types)
	------------------------------------------------------------
	All cross-module data shapes. Import these with:
	  local Types = require(Shared.Types)
	then annotate: local foo: Types.WeaponDef = ...

	No runtime code lives here — just type exports.
]]

-- A single weapon definition. Stored in ItemRegistry; referenced by string key.
export type WeaponDef = {
	weaponId: string,
	displayName: string,
	damage: number,
	maxAmmo: number,
	fireRateRps: number,   -- rounds per second
	range: number,         -- studs
	spread: number,        -- degrees of random deviation per shot
	reloadTime: number,    -- seconds
	viewmodelName: string, -- name of the template Model in ReplicatedStorage
}

-- Authoritative hold state stored per player on the server.
export type HoldState = {
	kind: "Weapon" | "Prop" | "None",
	instance: Instance?,
	weaponId: string?,
}

-- The constraint rig built by DragService.createHoldRig and returned to the client.
export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

-- Snapshot of CollisionGroups before a drag rig is applied.
export type CollisionSnapshot = { [BasePart]: string }

-- Snapshot of Anchored state before unanchoring for drag.
export type AnchorSnapshot = { [BasePart]: boolean }

-- Drag session: the full server-side state for one active prop hold.
export type DragSession = {
	object: Instance,
	primary: BasePart,
	rig: HoldRig,
	welds: { WeldConstraint },
	anchoredSnapshot: AnchorSnapshot,
	collisionSnapshot: CollisionSnapshot,
	connections: { RBXScriptConnection },
	boundingRadius: number,
	breachTime: number,
}

return {}
