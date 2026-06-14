--!strict

--[[
	Shared configuration for the First-Person Pickup & Inspection system.
	Adjust these values to tune feel without touching controller logic.
]]

local Config = {}

-- Detection
Config.PICKUP_TAG = "Interactable"
Config.PICKUP_ATTRIBUTE = "Pickupable"

-- Distances (studs)
Config.MAX_PICKUP_DISTANCE = 12
Config.HOLD_DISTANCE = 4.5
Config.HOLD_VERTICAL_OFFSET = -0.35

-- Server validation tolerances
Config.CAMERA_POSITION_TOLERANCE = 3.5
Config.RAYCAST_TOLERANCE = 1.25
Config.MAX_HOLD_DISTANCE = Config.HOLD_DISTANCE + 2

-- Physics
Config.ALIGN_POSITION_RESPONSIVENESS = 200
Config.ALIGN_POSITION_MAX_FORCE = 50_000
Config.ALIGN_POSITION_MAX_VELOCITY = 45

Config.ALIGN_ORIENTATION_RESPONSIVENESS = 200
Config.ALIGN_ORIENTATION_MAX_TORQUE = 50_000
Config.ALIGN_ORIENTATION_MAX_ANGULAR_VELOCITY = 25

Config.COLLISION_GROUP_HELD = "PickupHeld"
Config.COLLISION_GROUP_CHARACTER = "PickupCharacter"

-- Rotation (hold R + move mouse)
Config.ROTATION_MOUSE_SENSITIVITY = 0.004
Config.ROTATION_PITCH_LIMIT = math.rad(85)

-- Input
Config.PICKUP_KEY = Enum.KeyCode.E
Config.ROTATE_KEY = Enum.KeyCode.R
Config.DROP_KEY = Enum.KeyCode.G

-- Visual feedback
Config.HIGHLIGHT_FILL_COLOR = Color3.fromRGB(120, 200, 255)
Config.HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
Config.HIGHLIGHT_FILL_TRANSPARENCY = 0.85

return Config
