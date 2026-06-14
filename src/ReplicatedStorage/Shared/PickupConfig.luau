--!strict
--[[
	Shared configuration for the first-person object pickup and inspection system.
]]

local PickupConfig = {
	-- Detection
	INTERACT_TAG = "Interactable",
	INTERACT_ATTRIBUTE = "Interactable",

	-- Distances (studs)
	MAX_PICKUP_DISTANCE = 12,
	HOLD_DISTANCE = 4,
	HOLD_VERTICAL_OFFSET = -0.25,

	-- Rotation while holding R
	ROTATION_SENSITIVITY = 0.004,

	-- AlignPosition / AlignOrientation tuning (prevents flinging)
	ALIGN_MAX_FORCE = 100_000,
	ALIGN_MAX_VELOCITY = 60,
	ALIGN_RESPONSIVENESS = 200,
	ORIENT_MAX_TORQUE = 100_000,
	ORIENT_MAX_ANGULAR_VELOCITY = 40,
	ORIENT_RESPONSIVENESS = 200,

	-- Collision groups
	COLLISION_GROUP_PLAYER = "PickupPlayer",
	COLLISION_GROUP_HELD = "PickupHeld",
	COLLISION_GROUP_DEFAULT = "Default",

	-- Blender pivot correction: auto-correct when pivot is this far from bbox center (ratio of bbox diagonal)
	PIVOT_CORRECTION_THRESHOLD = 0.25,

	-- Hold anchor part name (replicated in Workspace)
	HOLD_TARGET_NAME = "PickupHoldTarget",

	-- Input
	KEY_PICKUP = Enum.KeyCode.E,
	KEY_DROP = Enum.KeyCode.E,
	KEY_ROTATE = Enum.KeyCode.R,
}

return PickupConfig
