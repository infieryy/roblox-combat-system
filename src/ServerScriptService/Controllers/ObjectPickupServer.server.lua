local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local PickupPhysicsUtil = require(script.Parent.Parent.Modules.PickupPhysicsUtil)

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "ObjectPickupRemote"
local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"
local MAX_PICKUP_DISTANCE = 12
local MAX_CAMERA_TO_HEAD_DISTANCE = 3
local HOLD_DISTANCE = 4.5
local MAX_HOLD_DISTANCE = 7

type HoldState = {
	objectData: PickupPhysicsUtil.ObjectData,
	rig: PickupPhysicsUtil.HoldRig,
}

local heldByPlayer: { [Player]: HoldState } = {}
local heldByRootPart: { [BasePart]: Player } = {}

local remotesFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = REMOTES_FOLDER_NAME
	remotesFolder.Parent = ReplicatedStorage
end

local pickupRemote = remotesFolder:FindFirstChild(REMOTE_NAME)
if not pickupRemote then
	pickupRemote = Instance.new("RemoteEvent")
	pickupRemote.Name = REMOTE_NAME
	pickupRemote.Parent = remotesFolder
end
pickupRemote = pickupRemote :: RemoteEvent

local function getHead(character: Model): BasePart?
	return character:FindFirstChild("Head") :: BasePart?
end

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

local function isCameraReasonable(character: Model, cameraCFrame: CFrame): boolean
	local head = getHead(character)
	if not head then
		return false
	end

	return (cameraCFrame.Position - head.Position).Magnitude <= MAX_CAMERA_TO_HEAD_DISTANCE
end

local function raycastHitsTarget(character: Model, cameraCFrame: CFrame, target: Instance): boolean
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local result = workspace:Raycast(
		cameraCFrame.Position,
		cameraCFrame.LookVector * MAX_PICKUP_DISTANCE,
		raycastParams
	)

	if not result then
		return false
	end

	return result.Instance == target or result.Instance:IsDescendantOf(target)
end

local function releasePlayerHold(player: Player)
	local holdState = heldByPlayer[player]
	if not holdState then
		return
	end

	heldByPlayer[player] = nil
	heldByRootPart[holdState.objectData.rootPart] = nil
	holdState.rig.destroy()
	PickupPhysicsUtil.setNetworkOwnership(holdState.objectData.rootPart, nil)
	pickupRemote:FireClient(player, "HoldingState", false)
end

local function tryPickup(player: Player, targetInstance: Instance, cameraCFrame: CFrame)
	local character = player.Character
	if not character then
		return
	end

	if not isCameraReasonable(character, cameraCFrame) then
		return
	end

	local interactableRoot = findInteractableRoot(targetInstance)
	if not interactableRoot then
		return
	end

	local objectData = PickupPhysicsUtil.getObjectData(interactableRoot)
	if not objectData then
		return
	end

	if PickupPhysicsUtil.hasAnchoredParts(objectData.parts) then
		return
	end

	if heldByRootPart[objectData.rootPart] then
		return
	end

	local head = getHead(character)
	if not head then
		return
	end

	if (objectData.boundingCenterWorld - head.Position).Magnitude > MAX_PICKUP_DISTANCE then
		return
	end

	if not raycastHitsTarget(character, cameraCFrame, interactableRoot) then
		return
	end

	releasePlayerHold(player)

	local initialTargetCFrame = cameraCFrame * CFrame.new(0, 0, -HOLD_DISTANCE)
	local rig = PickupPhysicsUtil.createHoldRig(objectData, character, initialTargetCFrame)
	PickupPhysicsUtil.setNetworkOwnership(objectData.rootPart, player)

	heldByPlayer[player] = {
		objectData = objectData,
		rig = rig,
	}
	heldByRootPart[objectData.rootPart] = player

	pickupRemote:FireClient(player, "HoldingState", true, interactableRoot)
end

local function updateHoldTarget(player: Player, cameraCFrame: CFrame, rotationOffset: CFrame?)
	local holdState = heldByPlayer[player]
	if not holdState then
		return
	end

	local character = player.Character
	if not character then
		releasePlayerHold(player)
		return
	end

	if not isCameraReasonable(character, cameraCFrame) then
		return
	end

	if not holdState.objectData.rootPart:IsDescendantOf(workspace) then
		releasePlayerHold(player)
		return
	end

	local appliedRotation = (rotationOffset or CFrame.identity).Rotation
	local targetCFrame = cameraCFrame * CFrame.new(0, 0, -HOLD_DISTANCE) * appliedRotation

	if (targetCFrame.Position - cameraCFrame.Position).Magnitude > MAX_HOLD_DISTANCE then
		return
	end

	holdState.rig.targetPart.CFrame = targetCFrame
end

pickupRemote.OnServerEvent:Connect(function(player, action: string, payload)
	if action == "RequestPickup" then
		if type(payload) ~= "table" then
			return
		end

		local target = payload.target
		local cameraCFrame = payload.cameraCFrame

		if typeof(target) ~= "Instance" or typeof(cameraCFrame) ~= "CFrame" then
			return
		end

		tryPickup(player, target, cameraCFrame)
		return
	end

	if action == "UpdateHold" then
		if type(payload) ~= "table" then
			return
		end

		local cameraCFrame = payload.cameraCFrame
		local rotationOffset = payload.rotationOffset

		if typeof(cameraCFrame) ~= "CFrame" then
			return
		end
		if rotationOffset ~= nil and typeof(rotationOffset) ~= "CFrame" then
			return
		end

		updateHoldTarget(player, cameraCFrame, rotationOffset)
		return
	end

	if action == "Drop" then
		releasePlayerHold(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	releasePlayerHold(player)
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function()
		releasePlayerHold(player)
	end)
end)
