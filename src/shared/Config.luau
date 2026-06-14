--!strict
--[[
	Config
	------
	Single source of truth for every tunable value used by the pickup system.
	Both the client and the server require this module so behaviour stays in sync
	and there are no "magic numbers" buried inside the controllers.
]]

export type ConfigType = {
	-- Detection
	Tag: string,
	Attribute: string,

	-- Distances (studs)
	MaxPickupDistance: number,
	MaxHoldDistance: number,
	ServerDistanceTolerance: number,

	-- Hold offset in front of the camera
	HoldDistanceBase: number,
	HoldDistancePadding: number,
	HoldDistanceMin: number,
	HoldDistanceMax: number,

	-- Object limits
	MaxObjectMass: number,

	-- AlignPosition tuning
	PositionResponsiveness: number,
	PositionMaxVelocity: number,
	ForceMultiplier: number,

	-- AlignOrientation tuning
	OrientationResponsiveness: number,
	MaxAngularVelocity: number,
	TorqueMultiplier: number,

	-- Collision groups
	CharacterCollisionGroup: string,
	HeldCollisionGroup: string,

	-- Camera / input
	MouseSensitivity: number,
	MinPitch: number,
	MaxPitch: number,
	RotateSensitivity: number,

	-- Server housekeeping
	LeashCheckInterval: number,
}

local Config: ConfigType = {
	------------------------------------------------------------------
	-- Detection
	------------------------------------------------------------------
	-- A target is interactable if it (or an ancestor) has this
	-- CollectionService tag OR this boolean attribute set to true.
	Tag = "Interactable",
	Attribute = "Interactable",

	------------------------------------------------------------------
	-- Distances
	------------------------------------------------------------------
	-- How far the client raycast reaches when looking for a pickup.
	MaxPickupDistance = 12,
	-- Server force-drops the object if it ever leaves this radius (anti-cheat leash).
	MaxHoldDistance = 18,
	-- Slack added to the server side distance check to account for latency.
	ServerDistanceTolerance = 4,

	------------------------------------------------------------------
	-- Hold offset (object floats this far in front of the camera)
	------------------------------------------------------------------
	HoldDistanceBase = 4,
	HoldDistancePadding = 1.2,
	HoldDistanceMin = 3,
	HoldDistanceMax = 9,

	------------------------------------------------------------------
	-- Object limits
	------------------------------------------------------------------
	-- Reject anything heavier than this (rough mass units). Set huge to disable.
	MaxObjectMass = 500,

	------------------------------------------------------------------
	-- AlignPosition (drag the object to its goal point)
	------------------------------------------------------------------
	PositionResponsiveness = 35,
	PositionMaxVelocity = 80,
	-- MaxForce = mass * gravity * ForceMultiplier. Big enough to carry the
	-- object snappily, capped so it can never violently fling anything.
	ForceMultiplier = 50,

	------------------------------------------------------------------
	-- AlignOrientation (rotate the object to its goal orientation)
	------------------------------------------------------------------
	OrientationResponsiveness = 40,
	MaxAngularVelocity = 30,
	-- MaxTorque = max(mass, 1) * TorqueMultiplier.
	TorqueMultiplier = 8000,

	------------------------------------------------------------------
	-- Collision groups (created at runtime by the server)
	------------------------------------------------------------------
	CharacterCollisionGroup = "PickupCharacters",
	HeldCollisionGroup = "PickupHeldObjects",

	------------------------------------------------------------------
	-- Camera / input
	------------------------------------------------------------------
	-- Radians of camera rotation per pixel of mouse movement.
	MouseSensitivity = 0.003,
	MinPitch = math.rad(-80),
	MaxPitch = math.rad(80),
	-- Radians of object rotation per pixel of mouse movement while inspecting (hold R).
	RotateSensitivity = 0.01,

	------------------------------------------------------------------
	-- Server housekeeping
	------------------------------------------------------------------
	-- Seconds between server-side leash / validity checks.
	LeashCheckInterval = 0.25,
}

return Config
