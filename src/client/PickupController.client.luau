--!strict
--[[
	PickupController (LocalScript)
	------------------------------
	The player-facing controller. Responsibilities:
	  * boot the first-person camera,
	  * raycast from the centre of the screen every frame to find interactables,
	  * show a minimal crosshair + prompt HUD,
	  * E to pick up / drop, hold R + move mouse to rotate the held object,
	  * while holding, drive the AlignPosition / AlignOrientation goals locally
	    (the client is the network owner, so this is zero-lag and needs no
	    per-frame remote traffic).

	Controls:
	  E        - pick up the object you're looking at / drop the held one
	  Hold R   - move the mouse to rotate (inspect) the held object
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")

local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PhysicsUtil = require(Shared:WaitForChild("PhysicsUtil"))
local Interactable = require(Shared:WaitForChild("Interactable"))

local CameraController = require(script.Parent:WaitForChild("CameraController"))
-- Drag-state bridge: lets the combat layer holster the weapon while a pickup is
-- being held / inspected. The pickup system is the sole writer.
local HoldState = require(script.Parent:WaitForChild("HoldState"))

local LocalPlayer = Players.LocalPlayer

local RENDER_NAME = "PickupControllerUpdate"
-- After the camera update so we read a fresh camera CFrame this frame.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local remotes = Remotes.get()

type Hold = {
	interactable: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
}

local currentTarget: Instance? = nil
local hold: Hold? = nil
-- Accumulated inspection rotation (in camera-relative space).
local inspectRotation = CFrame.identity

------------------------------------------------------------------
-- Raycast params (rebuilt each frame to exclude the live character)
------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshRayFilter()
	local filter: { Instance } = {}
	local character = LocalPlayer.Character
	if character then
		table.insert(filter, character)
	end
	if hold then
		table.insert(filter, hold.interactable)
	end
	rayParams.FilterDescendantsInstances = filter
end

------------------------------------------------------------------
-- HUD (crosshair + prompt)
------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PickupHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local crosshair = Instance.new("Frame")
crosshair.Name = "Crosshair"
crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
crosshair.Position = UDim2.fromScale(0.5, 0.5)
crosshair.Size = UDim2.fromOffset(6, 6)
crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
crosshair.BackgroundTransparency = 0.2
crosshair.BorderSizePixel = 0
local crosshairCorner = Instance.new("UICorner")
crosshairCorner.CornerRadius = UDim.new(1, 0)
crosshairCorner.Parent = crosshair
crosshair.Parent = gui

local prompt = Instance.new("TextLabel")
prompt.Name = "Prompt"
prompt.AnchorPoint = Vector2.new(0.5, 0.5)
prompt.Position = UDim2.fromScale(0.5, 0.62)
prompt.Size = UDim2.fromOffset(360, 28)
prompt.BackgroundTransparency = 1
prompt.TextColor3 = Color3.new(1, 1, 1)
prompt.TextStrokeTransparency = 0.4
prompt.TextScaled = false
prompt.TextSize = 20
prompt.Font = Enum.Font.GothamMedium
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local function instanceDisplayName(instance: Instance): string
	local name = instance.Name
	if name == "" then
		return "object"
	end
	return name
end

local function updateHud()
	if hold then
		crosshair.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
		prompt.Visible = true
		prompt.Text = "[E] Drop      [Hold R] Rotate"
	elseif currentTarget then
		crosshair.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
		prompt.Visible = true
		prompt.Text = string.format("[E] Pick up %s", instanceDisplayName(currentTarget))
	else
		crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
		prompt.Visible = false
		prompt.Text = ""
	end
end

------------------------------------------------------------------
-- Per-frame update
------------------------------------------------------------------

local function updateHeldGoals()
	local h = hold
	if not h then
		return
	end
	-- The constraint rig could have been torn down by the server (leash/death)
	-- before our DropGranted arrives; bail out safely.
	if not h.alignPosition.Parent or not h.alignOrientation.Parent then
		return
	end

	local camCFrame = CameraController.getCFrame()
	local goalPosition = camCFrame.Position + camCFrame.LookVector * h.holdDistance

	h.alignPosition.Position = goalPosition
	h.alignOrientation.CFrame = camCFrame.Rotation * inspectRotation
end

local function updateTargeting()
	if hold then
		currentTarget = nil
		return
	end

	refreshRayFilter()

	local camCFrame = CameraController.getCFrame()
	local origin = camCFrame.Position
	local direction = camCFrame.LookVector * Config.MaxPickupDistance

	local result = workspace:Raycast(origin, direction, rayParams)
	if result then
		currentTarget = Interactable.resolve(result.Instance)
	else
		currentTarget = nil
	end
end

local function onRenderStep(_dt: number)
	if hold then
		updateHeldGoals()
	else
		updateTargeting()
	end
	updateHud()
end

------------------------------------------------------------------
-- Object inspection rotation (driven by the camera controller)
------------------------------------------------------------------

CameraController.RotateDeltaCallback = function(delta: Vector2)
	if not hold then
		return
	end
	-- Yaw around the camera's up axis, pitch around the camera's right axis.
	local rx = -delta.Y * Config.RotateSensitivity
	local ry = -delta.X * Config.RotateSensitivity
	local step = CFrame.fromAxisAngle(Vector3.yAxis, ry) * CFrame.fromAxisAngle(Vector3.xAxis, rx)
	inspectRotation = step * inspectRotation
end

------------------------------------------------------------------
-- Input
------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		if hold then
			remotes.DropRequest:FireServer()
		elseif currentTarget then
			remotes.PickupRequest:FireServer(currentTarget)
		end
	elseif input.KeyCode == Enum.KeyCode.R then
		if hold then
			CameraController.setRotateMode(true)
			HoldState.setRotating(true)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.KeyCode == Enum.KeyCode.R then
		CameraController.setRotateMode(false)
		HoldState.setRotating(false)
	end
end)

------------------------------------------------------------------
-- Remote responses
------------------------------------------------------------------

remotes.PickupGranted.OnClientEvent:Connect(function(interactable: Instance, primary: BasePart)
	if typeof(primary) ~= "Instance" or not primary:IsA("BasePart") then
		return
	end

	-- The rig is created server-side; wait for it to replicate down.
	local alignPosition = primary:WaitForChild("PickupHoldAlignPosition", 2)
	local alignOrientation = primary:WaitForChild("PickupHoldAlignOrientation", 2)
	if not (alignPosition and alignPosition:IsA("AlignPosition")) then
		return
	end
	if not (alignOrientation and alignOrientation:IsA("AlignOrientation")) then
		return
	end

	inspectRotation = CFrame.identity
	hold = {
		interactable = interactable,
		primary = primary,
		alignPosition = alignPosition :: AlignPosition,
		alignOrientation = alignOrientation :: AlignOrientation,
		holdDistance = PhysicsUtil.getHoldDistance(interactable),
	}
	-- Tell the combat layer to holster: you can't shoot while carrying an object.
	HoldState.setHolding(true)
end)

remotes.DropGranted.OnClientEvent:Connect(function()
	hold = nil
	currentTarget = nil
	inspectRotation = CFrame.identity
	CameraController.setRotateMode(false)
	-- Hands are free again; the combat layer may re-equip.
	HoldState.setHolding(false)
end)

------------------------------------------------------------------
-- Boot
------------------------------------------------------------------

CameraController.start()
RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, onRenderStep)
