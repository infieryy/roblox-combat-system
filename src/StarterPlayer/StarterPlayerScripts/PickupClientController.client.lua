--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PhysicsPickupUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PhysicsPickupUtil"))

type InteractableRoot = BasePart | Model

local REMOTE_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "ObjectPickupRemote"
local RAYCAST_DISTANCE = 14
local CAMERA_UPDATE_RATE = 1 / 30

local localPlayer = Players.LocalPlayer
local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()

local remotesFolder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER_NAME)
local pickupRemote = remotesFolder:WaitForChild(REMOTE_NAME) :: RemoteEvent

local hoveredTarget: InteractableRoot? = nil
local isHolding = false
local isRotateHeld = false
local lastCameraUpdateAt = 0

local lastRayOrigin = Vector3.zero
local lastRayDirection = Vector3.zero

local function getCurrentCamera(): Camera?
	return Workspace.CurrentCamera
end

local function buildRaycastParams(): RaycastParams
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true
	return raycastParams
end

local function raycastInteractable(camera: Camera): InteractableRoot?
	local viewportCenter = camera.ViewportSize * 0.5
	local ray = camera:ViewportPointToRay(viewportCenter.X, viewportCenter.Y, 0)
	local rayOrigin = ray.Origin
	local rayDirection = ray.Direction * RAYCAST_DISTANCE

	lastRayOrigin = rayOrigin
	lastRayDirection = rayDirection

	local result = Workspace:Raycast(rayOrigin, rayDirection, buildRaycastParams())
	if not result then
		return nil
	end

	local interactableRoot = PhysicsPickupUtil.FindInteractableRoot(result.Instance)
	if interactableRoot and (interactableRoot:IsA("Model") or interactableRoot:IsA("BasePart")) then
		return interactableRoot
	end

	return nil
end

local function requestPickup()
	local camera = getCurrentCamera()
	if not camera then
		return
	end

	if isHolding then
		pickupRemote:FireServer({
			Action = "Drop",
		})
		return
	end

	if not hoveredTarget then
		return
	end

	pickupRemote:FireServer({
		Action = "RequestPickup",
		Target = hoveredTarget,
		CameraCFrame = camera.CFrame,
		RayOrigin = lastRayOrigin,
		RayDirection = lastRayDirection,
	})
end

local function updateHeldObjectNetwork()
	if not isHolding then
		return
	end

	local camera = getCurrentCamera()
	if not camera then
		return
	end

	local now = os.clock()
	if now - lastCameraUpdateAt >= CAMERA_UPDATE_RATE then
		pickupRemote:FireServer({
			Action = "UpdateHold",
			CameraCFrame = camera.CFrame,
		})
		lastCameraUpdateAt = now
	end

	if isRotateHeld then
		local mouseDelta = UserInputService:GetMouseDelta()
		if mouseDelta.Magnitude > 0 then
			pickupRemote:FireServer({
				Action = "Rotate",
				Delta = mouseDelta,
			})
		end
	end
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		requestPickup()
	elseif input.KeyCode == Enum.KeyCode.R then
		if isHolding then
			isRotateHeld = true
		end
	end
end

local function onInputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.R then
		isRotateHeld = false
	end
end

pickupRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	if payload.Action ~= "HoldState" then
		return
	end

	isHolding = payload.Holding == true
	if not (isHolding and typeof(payload.Target) == "Instance" and (payload.Target:IsA("Model") or payload.Target:IsA("BasePart"))) then
		isRotateHeld = false
	end
end)

localPlayer.CharacterAdded:Connect(function(newCharacter: Model)
	character = newCharacter
	isRotateHeld = false
	if isHolding then
		pickupRemote:FireServer({
			Action = "Drop",
		})
	end
end)

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

RunService.RenderStepped:Connect(function()
	local camera = getCurrentCamera()
	if camera and not isHolding then
		hoveredTarget = raycastInteractable(camera)
	elseif isHolding then
		hoveredTarget = nil
	end

	updateHeldObjectNetwork()
end)
