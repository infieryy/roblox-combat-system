--!nonstrict
--[[
	PickupController  (LocalScript)
	-----------------------------------------------------------------------------
	First-person client controller for the Pickup & Inspection system.

	Loop:
	  * Every frame, raycast from the centre of the first-person camera.
	  * Highlight whatever interactable we are looking at and show a prompt.
	  * Press E  -> request pickup (or drop if already holding).
	  * Hold R   -> freeze the view and rotate the held object with the mouse
	                ("My Summer Car" style inspection).

	Because the server transfers network ownership of the held object to us, we
	steer the AlignPosition/AlignOrientation goals locally every frame. That
	means the drag is simulated on our own machine = zero perceived lag, and the
	resulting CFrame replicates outward to the server and other players for free.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Pickup")
local Config = require(Shared:WaitForChild("PickupConfig"))
local PhysicsUtil = require(Shared:WaitForChild("PhysicsUtil"))
local Net = require(Shared:WaitForChild("Net"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local character: Model? = nil

-- What we are currently looking at (only meaningful when not holding).
local targetRoot: Instance? = nil

-- Active hold (nil when empty-handed).
local hold: {
	root: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	rotationOffset: CFrame,
}? = nil

-- Inspection (hold-R) state.
local rotating = false
local frozenCameraCFrame: CFrame? = nil

--------------------------------------------------------------------------------
-- Raycast params (rebuilt when the character changes)
--------------------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshFilter()
	local list = {}
	if character then
		table.insert(list, character)
	end
	if hold then
		table.insert(list, hold.root)
	end
	raycastParams.FilterDescendantsInstances = list
end

--------------------------------------------------------------------------------
-- Visuals: reusable Highlight + crosshair/prompt UI
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PickupGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local highlight = Instance.new("Highlight")
highlight.Name = "PickupHighlight"
highlight.FillTransparency = 0.7
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
highlight.Enabled = false
highlight.Adornee = nil
-- Parked on the persistent PlayerGui; the Adornee property drives what is shown.
highlight.Parent = gui

local crosshair = Instance.new("Frame")
crosshair.Name = "Crosshair"
crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
crosshair.Position = UDim2.fromScale(0.5, 0.5)
crosshair.Size = UDim2.fromOffset(6, 6)
crosshair.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
crosshair.BackgroundTransparency = 0.3
crosshair.BorderSizePixel = 0
crosshair.Parent = gui
local crosshairCorner = Instance.new("UICorner")
crosshairCorner.CornerRadius = UDim.new(1, 0)
crosshairCorner.Parent = crosshair

local prompt = Instance.new("TextLabel")
prompt.Name = "Prompt"
prompt.AnchorPoint = Vector2.new(0.5, 0)
prompt.Position = UDim2.fromScale(0.5, 0.62)
prompt.Size = UDim2.fromOffset(360, 28)
prompt.BackgroundTransparency = 1
prompt.TextColor3 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency = 0.4
prompt.TextScaled = false
prompt.TextSize = 20
prompt.Font = Enum.Font.GothamMedium
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

--------------------------------------------------------------------------------
-- Looking / targeting (only while empty-handed)
--------------------------------------------------------------------------------

local function castFromCamera(): RaycastResult?
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * Config.MaxPickupDistance
	return workspace:Raycast(origin, direction, raycastParams)
end

local function updateLook()
	local result = castFromCamera()
	local root: Instance? = nil
	if result then
		root = PhysicsUtil.resolvePickupRoot(result.Instance, Config.InteractTag, Config.InteractAttribute)
		-- Skip objects already held by someone.
		if root and root:GetAttribute(Config.HeldByAttribute) then
			root = nil
		end
	end

	targetRoot = root
	if root then
		highlight.Adornee = root
		highlight.Enabled = true
		setPrompt(("[%s] Pick Up"):format(Config.PickupKey.Name))
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		setPrompt(nil)
	end
end

--------------------------------------------------------------------------------
-- Holding / steering the constraints
--------------------------------------------------------------------------------

-- World CFrame where the object's centre should sit, oriented by the camera and
-- the accumulated inspection rotation.
local function computeGoalCFrame(): CFrame
	local camCF = (rotating and frozenCameraCFrame) or camera.CFrame
	local front = camCF * CFrame.new(0, 0, -Config.HoldDistance)
	-- Position from `front`, rotation = camera rotation * inspection offset.
	return CFrame.new(front.Position) * (front.Rotation * hold.rotationOffset)
end

local function steerHold()
	if not hold then
		return
	end
	-- Bail (and let server clean up) if the rig vanished.
	if not hold.alignPosition.Parent or not hold.alignOrientation.Parent then
		return
	end
	local goal = computeGoalCFrame()
	hold.alignPosition.Position = goal.Position
	hold.alignOrientation.CFrame = goal.Rotation
end

--------------------------------------------------------------------------------
-- Inspection (hold R) mode
--------------------------------------------------------------------------------

local function enterRotate()
	if rotating or not hold then
		return
	end
	rotating = true
	frozenCameraCFrame = camera.CFrame
	-- Freeze the view so the mouse drives the object, not the camera.
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	setPrompt("Rotating - release [" .. Config.RotateKey.Name .. "] to stop")
end

local function exitRotate()
	if not rotating then
		return
	end
	rotating = false
	frozenCameraCFrame = nil
	camera.CameraType = Enum.CameraType.Custom
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	if hold then
		setPrompt(("[%s] Drop   [%s] Rotate"):format(Config.PickupKey.Name, Config.RotateKey.Name))
	end
end

local function applyRotationFromMouse()
	if not (rotating and hold) then
		return
	end
	-- Keep the first-person view pinned while inspecting.
	if frozenCameraCFrame then
		camera.CFrame = frozenCameraCFrame
	end
	local delta = UserInputService:GetMouseDelta()
	if delta.Magnitude > 0 then
		local sens = Config.RotateSensitivity
		-- Rotate about the view's axes: yaw with X, pitch with Y.
		local deltaRot = CFrame.Angles(-delta.Y * sens, -delta.X * sens, 0)
		hold.rotationOffset = deltaRot * hold.rotationOffset
	end
end

--------------------------------------------------------------------------------
-- Net handlers
--------------------------------------------------------------------------------

Net.PickupGranted.OnClientEvent:Connect(function(root, primary, alignPosition, alignOrientation)
	if not (root and primary and alignPosition and alignOrientation) then
		return
	end

	-- Preserve the object's current orientation relative to the camera so it
	-- does not snap jarringly the instant it is grabbed.
	local front = camera.CFrame * CFrame.new(0, 0, -Config.HoldDistance)
	local rotationOffset = front.Rotation:ToObjectSpace(primary.CFrame.Rotation)

	hold = {
		root = root,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		rotationOffset = rotationOffset,
	}

	-- Don't let our own held object block our pickup raycast / vision.
	refreshFilter()

	highlight.Adornee = nil
	highlight.Enabled = false
	targetRoot = nil
	setPrompt(("[%s] Drop   [%s] Rotate"):format(Config.PickupKey.Name, Config.RotateKey.Name))
end)

Net.PickupEnded.OnClientEvent:Connect(function()
	exitRotate()
	hold = nil
	refreshFilter()
	setPrompt(nil)
end)

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function isPickupInput(input: InputObject): boolean
	return input.KeyCode == Config.PickupKey or input.KeyCode == Config.GamepadPickupKey
end

local function isRotateInput(input: InputObject): boolean
	return input.KeyCode == Config.RotateKey or input.KeyCode == Config.GamepadRotateKey
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if isPickupInput(input) then
		if hold then
			Net.RequestDrop:FireServer()
		elseif targetRoot then
			Net.RequestPickup:FireServer(targetRoot)
		end
	elseif isRotateInput(input) then
		if hold then
			enterRotate()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if isRotateInput(input) then
		exitRotate()
	end
end)

--------------------------------------------------------------------------------
-- Character lifecycle + first person
--------------------------------------------------------------------------------

local function onCharacter(char: Model)
	character = char
	refreshFilter()
	-- If we somehow respawn while holding, the server will have cleaned up.
	exitRotate()
	hold = nil
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end

if Config.ForceFirstPerson then
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

-- Keep the camera reference valid if it is swapped out.
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then
		camera = workspace.CurrentCamera
	end
end)

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

RunService.RenderStepped:Connect(function()
	if hold then
		applyRotationFromMouse()
		steerHold()
	else
		updateLook()
	end
end)
