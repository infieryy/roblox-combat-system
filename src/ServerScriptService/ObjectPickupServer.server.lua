--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PhysicsUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PhysicsUtil"))

local REMOTE_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "ObjectPickupRemote"

local MAX_PICKUP_DISTANCE = 12
local HOLD_DISTANCE = 4.75
local MAX_CAMERA_OFFSET_FROM_HEAD = 3
local MAX_ROTATION_DELTA = 40
local ROTATION_SENSITIVITY = 0.004

type HoldRig = PhysicsUtil.HoldRig

type HoldState = {
	target: Instance,
	rig: HoldRig,
	cameraCFrame: CFrame,
	rotationOffset: CFrame,
}

local heldByPlayer: { [Player]: HoldState } = {}
local holderByTarget: { [Instance]: Player } = {}

local function getOrCreateRemoteEvent(): RemoteEvent
	local remoteFolder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
	if remoteFolder ~= nil and not remoteFolder:IsA("Folder") then
		remoteFolder:Destroy()
		remoteFolder = nil
	end

	if remoteFolder == nil then
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = REMOTE_FOLDER_NAME
		remoteFolder.Parent = ReplicatedStorage
	end

	local remote = remoteFolder:FindFirstChild(REMOTE_NAME)
	if remote ~= nil and not remote:IsA("RemoteEvent") then
		remote:Destroy()
		remote = nil
	end

	if remote == nil then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = remoteFolder
	end

	return remote :: RemoteEvent
end

local pickupRemote = getOrCreateRemoteEvent()

local function getAliveCharacter(player: Player): Model?
	local character = player.Character
	if character == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end

	return character
end

local function getCharacterCameraRoot(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end

	return nil
end

local function sanitizeCameraCFrame(player: Player, clientCameraCFrame: any): CFrame?
	local character = getAliveCharacter(player)
	if character == nil then
		return nil
	end

	local cameraRoot = getCharacterCameraRoot(character)
	if cameraRoot == nil then
		return nil
	end

	if typeof(clientCameraCFrame) ~= "CFrame" then
		return cameraRoot.CFrame
	end

	if (clientCameraCFrame.Position - cameraRoot.Position).Magnitude > MAX_CAMERA_OFFSET_FROM_HEAD then
		return CFrame.lookAt(
			cameraRoot.Position,
			cameraRoot.Position + clientCameraCFrame.LookVector,
			Vector3.yAxis
		)
	end

	return clientCameraCFrame
end

local function applyHoldTransform(state: HoldState)
	local targetCFrame = state.cameraCFrame * CFrame.new(0, 0, -HOLD_DISTANCE) * state.rotationOffset
	PhysicsUtil.updateHoldTarget(state.rig, targetCFrame)
end

local function isStateStillValid(state: HoldState): boolean
	return state.target.Parent ~= nil and state.rig.rootPart.Parent ~= nil and state.rig.anchorPart.Parent ~= nil
end

local function clearHeldState(player: Player)
	local existing = heldByPlayer[player]
	if existing == nil then
		return
	end

	holderByTarget[existing.target] = nil
	heldByPlayer[player] = nil
	PhysicsUtil.destroyHoldRig(existing.rig)
	pickupRemote:FireClient(player, "HoldState", false)
end

local function validatePickup(player: Player, requestedInstance: any): (Instance?, CFrame?)
	if typeof(requestedInstance) ~= "Instance" then
		return nil, nil
	end

	local character = getAliveCharacter(player)
	if character == nil then
		return nil, nil
	end

	local cameraCFrame = sanitizeCameraCFrame(player, nil)
	if cameraCFrame == nil then
		return nil, nil
	end

	local interactable = PhysicsUtil.resolveInteractableRoot(requestedInstance)
	if interactable == nil then
		return nil, nil
	end

	if interactable:IsDescendantOf(character) then
		return nil, nil
	end

	local existingHolder = holderByTarget[interactable]
	if existingHolder ~= nil and existingHolder ~= player then
		return nil, nil
	end

	local rootPart, pivot = PhysicsUtil.getRootPartAndPivot(interactable)
	if rootPart == nil or pivot == nil then
		return nil, nil
	end

	local distance = (pivot.Position - cameraCFrame.Position).Magnitude
	if distance > MAX_PICKUP_DISTANCE then
		return nil, nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local rayDirection = pivot.Position - cameraCFrame.Position
	local raycastResult = workspace:Raycast(cameraCFrame.Position, rayDirection, raycastParams)
	if raycastResult ~= nil and not raycastResult.Instance:IsDescendantOf(interactable) then
		return nil, nil
	end

	return interactable, cameraCFrame
end

local function tryPickup(player: Player, requestedInstance: any)
	clearHeldState(player)

	local interactable, cameraCFrame = validatePickup(player, requestedInstance)
	if interactable == nil or cameraCFrame == nil then
		return
	end

	local character = getAliveCharacter(player)
	if character == nil then
		return
	end

	local rig = PhysicsUtil.createHoldRig(player, interactable, character)
	if rig == nil then
		return
	end

	local state: HoldState = {
		target = interactable,
		rig = rig,
		cameraCFrame = cameraCFrame,
		rotationOffset = CFrame.identity,
	}

	heldByPlayer[player] = state
	holderByTarget[interactable] = player
	applyHoldTransform(state)

	pickupRemote:FireClient(player, "HoldState", true, interactable)
end

local function updateHoldFromCamera(player: Player, cameraCFrame: any)
	local state = heldByPlayer[player]
	if state == nil then
		return
	end

	if not isStateStillValid(state) then
		clearHeldState(player)
		return
	end

	local sanitized = sanitizeCameraCFrame(player, cameraCFrame)
	if sanitized == nil then
		return
	end

	state.cameraCFrame = sanitized
	applyHoldTransform(state)
end

local function rotateHeldObject(player: Player, rotationDelta: any)
	local state = heldByPlayer[player]
	if state == nil then
		return
	end

	if not isStateStillValid(state) then
		clearHeldState(player)
		return
	end

	if typeof(rotationDelta) ~= "Vector2" then
		return
	end

	local deltaX = math.clamp(rotationDelta.X, -MAX_ROTATION_DELTA, MAX_ROTATION_DELTA)
	local deltaY = math.clamp(rotationDelta.Y, -MAX_ROTATION_DELTA, MAX_ROTATION_DELTA)

	local yaw = CFrame.fromAxisAngle(Vector3.yAxis, -deltaX * ROTATION_SENSITIVITY)
	local pitch = CFrame.fromAxisAngle(Vector3.xAxis, -deltaY * ROTATION_SENSITIVITY)

	state.rotationOffset = yaw * pitch * state.rotationOffset
	applyHoldTransform(state)
end

pickupRemote.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return
	end

	if action == "Pickup" then
		tryPickup(player, payload)
	elseif action == "Drop" then
		clearHeldState(player)
	elseif action == "UpdateHold" then
		updateHoldFromCamera(player, payload)
	elseif action == "Rotate" then
		rotateHeldObject(player, payload)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	clearHeldState(player)
end)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterRemoving:Connect(function()
		clearHeldState(player)
	end)
end)
