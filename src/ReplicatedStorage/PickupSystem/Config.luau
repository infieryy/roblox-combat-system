--!strict
--[[
	Config
	------
	Single source of truth for every tunable value in the pickup system.
	Shared by the client controller, the server controller and the physics
	utility module so behaviour stays consistent across the network boundary.

	All distances are in studs, all angles in radians and all forces in the
	Roblox SI-ish units (rowtons). Forces/torques are expressed *per unit of
	assembly mass* so that a light cardboard box and a heavy Blender anvil both
	feel responsive without the heavy one lagging behind the camera.
]]

export type Config = {
	-- Detection ----------------------------------------------------------
	Tag: string,
	Attribute: string,

	-- Pickup gating ------------------------------------------------------
	MaxPickupDistance: number,
	ServerDistanceSlack: number,

	-- Hold framing -------------------------------------------------------
	HoldDistanceBase: number,
	HoldDistanceSizeFactor: number,
	MinHoldDistance: number,
	MaxHoldDistanceClient: number,

	-- Server hold safety -------------------------------------------------
	MaxHoldDistance: number,
	HoldBreakMultiplier: number,

	-- Input --------------------------------------------------------------
	PickupKey: Enum.KeyCode,
	DropKey: Enum.KeyCode,
	RotateKey: Enum.KeyCode,
	RotateSensitivity: number,

	-- Networking ---------------------------------------------------------
	ClientPrediction: boolean,
	SendInterval: number,

	-- AlignPosition tuning ----------------------------------------------
	PositionResponsiveness: number,
	ForcePerMass: number,
	MinForce: number,
	MaxVelocity: number,

	-- AlignOrientation tuning -------------------------------------------
	OrientationResponsiveness: number,
	TorquePerMass: number,
	MinTorque: number,
	MaxAngularVelocity: number,
}

local Config: Config = {
	-- A CollectionService tag OR an attribute of the same name flags an
	-- object as grabbable. Either is enough, giving level designers two
	-- workflows (Tag editor or the Attribute panel).
	Tag = "Interactable",
	Attribute = "Interactable",

	-- How far the player can reach to begin a pickup.
	MaxPickupDistance = 12,
	-- The server re-runs the distance check but allows a margin so honest
	-- players are not rejected because of latency between aim and request.
	ServerDistanceSlack = 1.6,

	-- Resting distance in front of the camera is sized to the object so big
	-- meshes are pushed back far enough to stay fully in frame.
	HoldDistanceBase = 3.0,
	HoldDistanceSizeFactor = 0.6,
	MinHoldDistance = 2.5,
	MaxHoldDistanceClient = 9.0,

	-- Hard server ceiling for the requested goal position relative to the
	-- player's head. Anything beyond is clamped (UpdateGoal) and anything
	-- wildly beyond drops the object (heartbeat watchdog).
	MaxHoldDistance = 11.0,
	HoldBreakMultiplier = 2.0,

	PickupKey = Enum.KeyCode.E,
	DropKey = Enum.KeyCode.Q,
	RotateKey = Enum.KeyCode.R,
	-- Radians of object rotation per pixel of mouse movement while inspecting.
	RotateSensitivity = 0.0125,

	-- Drive the constraints locally on the owning client for instant feel,
	-- while still streaming the goal to the server for replication + auth.
	ClientPrediction = true,
	-- Goal stream rate (seconds). 1/30 keeps other clients smooth without
	-- flooding the network; the owner uses prediction so this is just sync.
	SendInterval = 1 / 30,

	-- Snappy but not rigid. Responsiveness 0-200; higher converges faster.
	PositionResponsiveness = 65,
	-- MaxForce scales with mass so heavy objects keep up. MinForce keeps very
	-- light objects from feeling floaty.
	ForcePerMass = 2500,
	MinForce = 35000,
	-- Velocity cap is the key anti-fling guard: the object can never build up
	-- enough speed to slam through geometry or yank the player around.
	MaxVelocity = 90,

	OrientationResponsiveness = 50,
	TorquePerMass = 4000,
	MinTorque = 45000,
	MaxAngularVelocity = 35,
}

return Config
