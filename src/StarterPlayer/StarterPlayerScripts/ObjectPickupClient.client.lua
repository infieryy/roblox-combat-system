--!strict

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local localPlayer = Players.LocalPlayer

local REMOTE_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "ObjectPickupRemote"

local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"
local PICKUP_KEY = Enum.KeyCode.E
local ROTATE_KEY = Enum.KeyCode.R

local RAYCAST_DISTANCE = 14
local HOLD_UPDATE_RATE = 60

local pickupRemote = ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME):WaitForChild(REMOTE_NAME) :: RemoteEvent

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local currentTarget: Instance? = nil
local heldTarget: Instance? = nil
local isHolding = false
local isRotating = false
local lastHoldSync = 0
local lastSentCameraCFrame: CFrame? = nil

local function isInteractable(instance: Instance?): boolean
	if instance == nil then
		return false
	end

	return CollectionService:HasTag(instance, INTERACTABLE_TAG) or instance:GetAttribute(INTERACTABLE_ATTRIBUTE) == true
end

local function resolveInteractableRoot(instance: Instance?): Instance?
	local cursor = instance
	while cursor ~= nil do
		if isInteractable(cursor) and (cursor:IsA("Model") or cursor:IsA("BasePart")) then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function updateRaycastFilter()
	local character = localPlayer.Character
	if character then
		raycastParams.FilterDescendantsInstances = { character }
	else
		raycastParams.FilterDescendantsInstances = {}
	end
end

local function raycastFromCameraCenter(): Instance?
	local camera = workspace.CurrentCamera
	if camera == nil then
		return nil
	end

	local viewportSize = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewportSize.X * 0.5, viewportSize.Y * 0.5)
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAYCAST_DISTANCE, raycastParams)
	if result == nil then
		return nil
	end

	return resolveInteractableRoot(result.Instance)
end

local function requestPickupOrDrop()
	if isHolding then
		pickupRemote:FireServer("Drop")
		return
	end

	if currentTarget ~= nil then
		pickupRemote:FireServer("Pickup", currentTarget)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then
		return
	end

	if input.KeyCode == PICKUP_KEY then
		requestPickupOrDrop()
	elseif input.KeyCode == ROTATE_KEY and isHolding then
		isRotating = true
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessedEvent: boolean)
	if input.KeyCode == ROTATE_KEY then
		isRotating = false
	end
end)

pickupRemote.OnClientEvent:Connect(function(eventName: any, holdState: any, target: any)
	if eventName ~= "HoldState" then
		return
	end

	isHolding = holdState == true
	heldTarget = if isHolding and typeof(target) == "Instance" then target else nil

	if not isHolding then
		isRotating = false
		lastSentCameraCFrame = nil
	end
end)

localPlayer.CharacterAdded:Connect(function()
	updateRaycastFilter()
end)

updateRaycastFilter()

RunService.RenderStepped:Connect(function()
	if not isHolding then
		currentTarget = raycastFromCameraCenter()
	else
		currentTarget = nil
	end

	local camera = workspace.CurrentCamera
	if not isHolding or camera == nil then
		return
	end

	if heldTarget ~= nil and heldTarget.Parent == nil then
		isHolding = false
		heldTarget = nil
		isRotating = false
		lastSentCameraCFrame = nil
		pickupRemote:FireServer("Drop")
		return
	end

	local now = os.clock()
	if now - lastHoldSync >= (1 / HOLD_UPDATE_RATE) then
		lastHoldSync = now
		local shouldSend =
			lastSentCameraCFrame == nil
			or (camera.CFrame.Position - lastSentCameraCFrame.Position).Magnitude > 0.01
			or camera.CFrame.LookVector:Dot(lastSentCameraCFrame.LookVector) < 0.9999

		if shouldSend then
			lastSentCameraCFrame = camera.CFrame
			pickupRemote:FireServer("UpdateHold", camera.CFrame)
		end
	end

	if isRotating then
		local mouseDelta = UserInputService:GetMouseDelta()
		if mouseDelta.Magnitude > 0 then
			pickupRemote:FireServer("Rotate", mouseDelta)
		end
	end
end)
