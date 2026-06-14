local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LOCAL_PLAYER = Players.LocalPlayer

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_EVENT_NAME = "ObjectPickupRemote"
local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"

local MAX_RAYCAST_DISTANCE = 12
local HOLD_UPDATE_RATE = 1 / 30
local ROTATION_SENSITIVITY = 0.2

local remotesFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
local pickupRemote = remotesFolder:WaitForChild(REMOTE_EVENT_NAME) :: RemoteEvent

local isHolding = false
local isRotating = false
local isPickupPending = false
local lookTarget: Instance? = nil
local lastSentAt = 0
local rotationAccumulator = Vector2.zero

local function hasInteractableMarker(instance: Instance): boolean
	if CollectionService:HasTag(instance, INTERACTABLE_TAG) then
		return true
	end

	return instance:GetAttribute(INTERACTABLE_ATTRIBUTE) == true
end

local function findInteractableFromHit(hitInstance: Instance?): Instance?
	local cursor = hitInstance
	while cursor do
		if (cursor:IsA("Model") or cursor:IsA("BasePart")) and hasInteractableMarker(cursor) then
			return cursor
		end
		cursor = cursor.Parent
	end

	return nil
end

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function getRaycastResult(): (RaycastResult?, Ray?)
	local camera = getCamera()
	if not camera then
		return nil, nil
	end

	local viewportSize = camera.ViewportSize
	local centerX = viewportSize.X * 0.5
	local centerY = viewportSize.Y * 0.5
	local ray = camera:ViewportPointToRay(centerX, centerY, 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local character = LOCAL_PLAYER.Character
	if character then
		params.FilterDescendantsInstances = { character }
	end

	return Workspace:Raycast(ray.Origin, ray.Direction * MAX_RAYCAST_DISTANCE, params), ray
end

local function attemptPickup()
	if isHolding or isPickupPending then
		return
	end

	local camera = getCamera()
	if not camera then
		return
	end

	local rayResult, ray = getRaycastResult()
	if not rayResult or not ray then
		return
	end

	local interactable = findInteractableFromHit(rayResult.Instance)
	if not interactable then
		return
	end

	pickupRemote:FireServer("Pickup", {
		target = interactable,
		rayOrigin = ray.Origin,
		rayDirection = ray.Direction,
		cameraCFrame = camera.CFrame,
	})

	isPickupPending = true
	rotationAccumulator = Vector2.zero
	lastSentAt = 0
end

local function dropHeldObject()
	if not isHolding and not isPickupPending then
		return
	end

	pickupRemote:FireServer("Drop")
	isHolding = false
	isRotating = false
	isPickupPending = false
	rotationAccumulator = Vector2.zero
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		if isPickupPending then
			return
		end

		if isHolding then
			dropHeldObject()
		else
			attemptPickup()
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.R and isHolding then
		isRotating = true
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessedEvent: boolean)
	if input.KeyCode == Enum.KeyCode.R then
		isRotating = false
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or not isHolding or not isRotating then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then
		rotationAccumulator += Vector2.new(-input.Delta.X, -input.Delta.Y) * ROTATION_SENSITIVITY
	end
end)

pickupRemote.OnClientEvent:Connect(function(action: string, payload)
	if action ~= "PickupState" or type(payload) ~= "table" then
		return
	end

	local holding = payload.isHolding == true
	isHolding = holding
	isPickupPending = false

	if not holding then
		isRotating = false
		rotationAccumulator = Vector2.zero
	end
end)

RunService.RenderStepped:Connect(function()
	local camera = getCamera()
	if not camera then
		return
	end

	local rayResult = getRaycastResult()
	lookTarget = if rayResult then findInteractableFromHit(rayResult.Instance) else nil

	if not isHolding then
		return
	end

	local now = os.clock()
	if now - lastSentAt < HOLD_UPDATE_RATE then
		return
	end

	local payload = {
		cameraCFrame = camera.CFrame,
	}

	if isRotating and rotationAccumulator.Magnitude > 0 then
		payload.rotationDelta = rotationAccumulator
		rotationAccumulator = Vector2.zero
	end

	pickupRemote:FireServer("UpdateHold", payload)
	lastSentAt = now
end)

LOCAL_PLAYER.CharacterRemoving:Connect(function()
	if isHolding or isPickupPending then
		dropHeldObject()
	end
end)
