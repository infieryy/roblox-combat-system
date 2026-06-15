--!strict
--[[
    Types
    -----
    Shared type exports used across client, server, and shared modules.
    Import with:  local Types = require(ReplicatedStorage.Shared.Types)
]]

-- Full definition of a weapon entry in ItemRegistry.
export type WeaponDef = {
    weaponId: string,
    displayName: string,
    damage: number,
    maxAmmo: number,
    -- Rounds per second (server enforces this as 1/fireRateRps minimum gap).
    fireRateRps: number,
    range: number,
    -- Max random cone spread radius in studs at 1 stud distance (unit-vector perturbation).
    spread: number,
    reloadTime: number,
    -- Name of the Model inside ReplicatedStorage.Assets.Viewmodels to clone.
    viewmodelName: string,
    -- CFrame offset from camera origin to muzzle tip (used by client for muzzle-flash origin).
    muzzleOffset: CFrame,
    -- How much mouse-movement delta the drag animation influences the viewmodel (XY).
    dragInfluence: Vector3,
}

-- Server-authoritative record of what one player is holding.
export type HoldState = {
    kind: "Weapon" | "Prop" | "None",
    instance: Instance?,
    weaponId: string?,
}

-- The three constraint objects that make up a drag rig.
-- Server creates and sends references; client steers Position/CFrame each frame.
export type HoldRig = {
    attachment: Attachment,
    alignPosition: AlignPosition,
    alignOrientation: AlignOrientation,
}

return {}
