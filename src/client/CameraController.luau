--!strict
--[[
	CameraController (ModuleScript)
	-------------------------------
	A self-contained, scriptable first-person camera. It owns the only read of
	the per-frame mouse delta so there is never any contention with the pickup
	controller.

	Two modes:
	  * Normal  : mouse delta drives camera yaw/pitch (look around).
	  * Rotate  : (player is holding R) camera is frozen and the mouse delta is
	              forwarded to RotateDeltaCallback so the held object can be spun.

	The camera is pinned to the character's head every frame, which keeps it
	locked to first person and lets the default control scripts move the
	character relative to where the player is looking.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")
local Config = require(Shared:WaitForChild("Config"))

local LocalPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

local RENDER_NAME = "PickupCameraUpdate"
-- Run just after the engine's default camera slot so we win the frame.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local CameraController = {}

local yaw = 0
local pitch = 0
local rotateMode = false
local started = false

-- Set by PickupController; receives the raw Vector2 mouse delta while in
-- rotate mode so the held object can be rotated.
CameraController.RotateDeltaCallback = nil :: ((delta: Vector2) -> ())?

local function getHead(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
end

-- Make a single part invisible locally (only on this client). Decals/faces ride
-- on the part and are not visible from inside the head, so parts are enough.
local function hideInstance(instance: Instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = 1
	end
end

-- Hide the local character so we get a clean first-person view. A scriptable
-- camera disables Roblox's built-in first-person auto-hide, so we replicate it.
-- LocalTransparencyModifier only affects this client, so other players still
-- see the full avatar.
local function hideCharacter(character: Model)
	for _, descendant in character:GetDescendants() do
		hideInstance(descendant)
	end
	character.DescendantAdded:Connect(hideInstance)
end

local function bindCharacter()
	if LocalPlayer.Character then
		hideCharacter(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(hideCharacter)
end

local function onRenderStep(_dt: number)
	-- Keep the mouse pinned to the centre so first-person look stays smooth and
	-- the delta keeps flowing even when the player isn't moving the cursor.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	local head = getHead()
	if not head then
		return
	end

	local delta = UserInputService:GetMouseDelta()

	if rotateMode then
		-- Camera stays still; hand the movement to the object inspector.
		local callback = CameraController.RotateDeltaCallback
		if callback then
			callback(delta)
		end
	else
		yaw -= delta.X * Config.MouseSensitivity
		pitch = math.clamp(
			pitch - delta.Y * Config.MouseSensitivity,
			Config.MinPitch,
			Config.MaxPitch
		)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(head.Position) * CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

-- True while the player is inspecting (holding R); freezes the camera.
function CameraController.setRotateMode(enabled: boolean)
	rotateMode = enabled
end

function CameraController.isRotateMode(): boolean
	return rotateMode
end

-- Current camera CFrame (origin + look direction) used for raycasts and the
-- hold-point calculation.
function CameraController.getCFrame(): CFrame
	return camera.CFrame
end

function CameraController.start()
	if started then
		return
	end
	started = true

	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	-- Re-seed yaw from wherever the default camera was pointing for a smooth
	-- hand-off, and refresh our camera reference whenever it changes.
	local _, startYaw, _ = camera.CFrame:ToEulerAnglesYXZ()
	yaw = startYaw

	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then
			camera = workspace.CurrentCamera
		end
	end)

	bindCharacter()

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, onRenderStep)
end

return CameraController
