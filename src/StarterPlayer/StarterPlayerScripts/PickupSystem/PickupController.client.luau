--!strict

--[[
	Client-side first-person pickup controller.
	Frame-perfect camera raycasts, input handling, and hold-target replication.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.PickupSystem.Config)
local PhysicsUtility = require(ReplicatedStorage.PickupSystem.PhysicsUtility)
local Remotes = require(ReplicatedStorage.PickupSystem.Remotes)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera or workspace:WaitForChild("Camera") :: Camera

local pickupRequest = Remotes.getPickupRequest()
local dropRequest = Remotes.getDropRequest()
local rotateUpdate = Remotes.getRotateUpdate()
local holdState = Remotes.getHoldState()

local currentTarget: Instance? = nil
local currentHighlight: Highlight? = nil
local heldModel: Model? = nil
local holdPart: BasePart? = nil
local inspectionRotation = CFrame.identity
local isRotating = false
local lastMousePosition: Vector2? = nil

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function getCharacter(): Model?
	return player.Character
end

local function updateRaycastFilter()
	local character = getCharacter()
	if character then
		raycastParams.FilterDescendantsInstances = { character }
	else
		raycastParams.FilterDescendantsInstances = {}
	end
end

local function isPickupable(instance: Instance): boolean
	if CollectionService:HasTag(instance, Config.PICKUP_TAG) then
		return true
	end

	if instance:GetAttribute(Config.PICKUP_ATTRIBUTE) == true then
		return true
	end

	if instance:IsA("BasePart") or instance:IsA("MeshPart") then
		if CollectionService:HasTag(instance, Config.PICKUP_TAG) then
			return true
		end
	end

	local model = PhysicsUtility.resolvePickupModel(instance, false)
	if model and (
		CollectionService:HasTag(model, Config.PICKUP_TAG)
		or model:GetAttribute(Config.PICKUP_ATTRIBUTE) == true
	) then
		return true
	end

	return false
end

local function getCameraRay(): (Vector3, Vector3)
	local viewportSize = camera.ViewportSize
	local screenCenter = viewportSize / 2
	local unitRay = camera:ViewportPointToRay(screenCenter.X, screenCenter.Y)
	return unitRay.Origin, unitRay.Direction * Config.MAX_PICKUP_DISTANCE
end

local function clearHighlight()
	if currentHighlight then
		currentHighlight:Destroy()
		currentHighlight = nil
	end
end

local function setHighlight(target: Instance)
	if currentTarget == target and currentHighlight then
		return
	end

	clearHighlight()
	currentTarget = target

	local adornee: Instance = PhysicsUtility.resolvePickupModel(target, false) or target

	local highlight = Instance.new("Highlight")
	highlight.Name = "PickupHighlight"
	highlight.Adornee = adornee
	highlight.FillColor = Config.HIGHLIGHT_FILL_COLOR
	highlight.OutlineColor = Config.HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency = Config.HIGHLIGHT_FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.Parent = adornee

	currentHighlight = highlight
end

local function performCameraRaycast(): RaycastResult?
	updateRaycastFilter()
	local origin, direction = getCameraRay()
	return workspace:Raycast(origin, direction, raycastParams)
end

local function findHoldPart(): BasePart?
	local character = getCharacter()
	if not character then
		return nil
	end

	return character:FindFirstChild("PickupHoldTarget") :: BasePart?
end

local function getHoldCFrame(): CFrame
	local holdOffset = CFrame.new(0, Config.HOLD_VERTICAL_OFFSET, -Config.HOLD_DISTANCE)
	return camera.CFrame * holdOffset * inspectionRotation
end

local function updateHoldTarget()
	if not heldModel then
		return
	end

	local targetHoldPart = holdPart or findHoldPart()
	if not targetHoldPart then
		return
	end

	holdPart = targetHoldPart
	targetHoldPart.CFrame = getHoldCFrame()
end

local function requestPickup()
	if heldModel then
		return
	end

	local result = performCameraRaycast()
	if not result then
		return
	end

	local target = result.Instance
	if not isPickupable(target) then
		return
	end

	pickupRequest:FireServer(target, result.Position, camera.CFrame)
end

local function requestDrop()
	if not heldModel then
		return
	end

	dropRequest:FireServer(true)
end

local function clampPitch(rotation: CFrame): CFrame
	local x, y, z = rotation:ToOrientation()
	x = math.clamp(x, -Config.ROTATION_PITCH_LIMIT, Config.ROTATION_PITCH_LIMIT)
	return CFrame.fromOrientation(x, y, z)
end

local function beginRotation()
	isRotating = true
	lastMousePosition = UserInputService:GetMouseLocation()
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
end

local function endRotation()
	isRotating = false
	lastMousePosition = nil
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	rotateUpdate:FireServer(inspectionRotation)
end

local function handleRotationInput()
	if not isRotating or not heldModel then
		return
	end

	local mousePosition = UserInputService:GetMouseLocation()
	if not lastMousePosition then
		lastMousePosition = mousePosition
		return
	end

	local delta = mousePosition - lastMousePosition
	lastMousePosition = mousePosition

	if delta.Magnitude < 0.001 then
		return
	end

	local yaw = -delta.X * Config.ROTATION_MOUSE_SENSITIVITY
	local pitch = -delta.Y * Config.ROTATION_MOUSE_SENSITIVITY

	local deltaRotation = CFrame.fromOrientation(pitch, yaw, 0)
	inspectionRotation = clampPitch(inspectionRotation * deltaRotation)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.PICKUP_KEY and input.UserInputState == Enum.UserInputState.Begin then
		if heldModel then
			requestDrop()
		else
			requestPickup()
		end
	elseif input.KeyCode == Config.ROTATE_KEY and input.UserInputState == Enum.UserInputState.Begin then
		if heldModel then
			beginRotation()
		end
	elseif input.KeyCode == Config.DROP_KEY and input.UserInputState == Enum.UserInputState.Begin then
		requestDrop()
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode == Config.ROTATE_KEY then
		endRotation()
	end
end

holdState.OnClientEvent:Connect(function(model: Model?)
	if model then
		heldModel = model
		holdPart = findHoldPart()
		inspectionRotation = CFrame.identity
	else
		heldModel = nil
		holdPart = nil
		inspectionRotation = CFrame.identity
		endRotation()
	end
end)

RunService:BindToRenderStep("PickupCameraRaycast", Enum.RenderPriority.Camera.Value + 1, function()
	if not heldModel then
		local result = performCameraRaycast()
		if result and isPickupable(result.Instance) then
			setHighlight(result.Instance)
		else
			currentTarget = nil
			clearHighlight()
		end
	end

	handleRotationInput()
	updateHoldTarget()
end)

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

player.CharacterAdded:Connect(function()
	heldModel = nil
	holdPart = nil
	inspectionRotation = CFrame.identity
	clearHighlight()
	updateRaycastFilter()
end)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local nextCamera = workspace.CurrentCamera
	if nextCamera then
		camera = nextCamera
		updateRaycastFilter()
	end
end)

updateRaycastFilter()
