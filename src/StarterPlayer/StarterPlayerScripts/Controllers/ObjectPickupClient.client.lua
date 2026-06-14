local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local pickupRemote = remotesFolder:WaitForChild("ObjectPickupRemote") :: RemoteEvent

local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"
local PICKUP_DISTANCE = 12
local UPDATE_RATE = 1 / 30
local ROTATION_SENSITIVITY = 0.0075

local currentTarget: Instance? = nil
local isHolding = false
local isRotating = false
local rotationOffset = CFrame.identity
local sendAccumulator = 0

local function isInteractable(instance: Instance): boolean
	return CollectionService:HasTag(instance, INTERACTABLE_TAG)
		or instance:GetAttribute(INTERACTABLE_ATTRIBUTE) == true
end

local function findInteractableRoot(instance: Instance?): Instance?
	local current = instance
	while current and current ~= workspace do
		if (current:IsA("Model") or current:IsA("BasePart")) and isInteractable(current) then
			return current
		end
		current = current.Parent
	end

	return nil
end

local function buildRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local character = player.Character
	if character then
		params.FilterDescendantsInstances = { character }
	else
		params.FilterDescendantsInstances = {}
	end

	params.IgnoreWater = true
	return params
end

local function updateTargetFromCrosshair(camera: Camera)
	local viewport = camera.ViewportSize
	local centerX = viewport.X * 0.5
	local centerY = viewport.Y * 0.5
	local centerRay = camera:ViewportPointToRay(centerX, centerY)
	local result = workspace:Raycast(centerRay.Origin, centerRay.Direction * PICKUP_DISTANCE, buildRaycastParams())

	if not result then
		currentTarget = nil
		return
	end

	currentTarget = findInteractableRoot(result.Instance)
end

local function requestPickup(camera: Camera)
	if not currentTarget then
		return
	end

	pickupRemote:FireServer("RequestPickup", {
		target = currentTarget,
		cameraCFrame = camera.CFrame,
	})
end

local function requestDrop()
	pickupRemote:FireServer("Drop")
end

pickupRemote.OnClientEvent:Connect(function(action: string, holdingState: boolean)
	if action ~= "HoldingState" then
		return
	end

	isHolding = holdingState
	if isHolding then
		rotationOffset = CFrame.identity
	else
		rotationOffset = CFrame.identity
		isRotating = false
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		if isHolding then
			requestDrop()
		else
			requestPickup(camera)
		end
	elseif input.KeyCode == Enum.KeyCode.R then
		if isHolding then
			isRotating = true
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.KeyCode == Enum.KeyCode.R then
		isRotating = false
	end
end)

RunService.RenderStepped:Connect(function(deltaTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	updateTargetFromCrosshair(camera)

	if not isHolding then
		return
	end

	if isRotating then
		local mouseDelta = UserInputService:GetMouseDelta()
		local pitch = -mouseDelta.Y * ROTATION_SENSITIVITY
		local yaw = -mouseDelta.X * ROTATION_SENSITIVITY
		rotationOffset = rotationOffset * CFrame.Angles(pitch, yaw, 0)
	end

	sendAccumulator += deltaTime
	if sendAccumulator < UPDATE_RATE then
		return
	end
	sendAccumulator = 0

	pickupRemote:FireServer("UpdateHold", {
		cameraCFrame = camera.CFrame,
		rotationOffset = rotationOffset,
	})
end)
