--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PhysicsPickupUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PhysicsPickupUtil"))

type InteractableRoot = BasePart | Model
type HoldConstraintBundle = {
	RootPart: BasePart,
	TargetRoot: InteractableRoot,
	ObjectAttachment: Attachment,
	AnchorPart: Part,
	AnchorAttachment: Attachment,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	RuntimeFolder: Folder,
	CollisionConstraints: { NoCollisionConstraint },
}

type HoldState = {
	TargetRoot: InteractableRoot,
	RootPart: BasePart,
	Bundle: HoldConstraintBundle,
	RotationOffset: CFrame,
	LastCameraCFrame: CFrame,
	HoldDistance: number,
	LastUpdate: number,
}

local REMOTE_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "ObjectPickupRemote"

local MAX_PICKUP_DISTANCE = 12
local MAX_HOLD_DISTANCE = 18
local DEFAULT_HOLD_DISTANCE = 4.5
local MIN_HOLD_DISTANCE = 2.8
local MAX_HOLD_DISTANCE_FROM_SIZE = 8
local MAX_CLIENT_RAY_DISTANCE = 16

local ROTATION_DEGREES_PER_PIXEL = 0.3
local MAX_ROTATION_DELTA = 35
local STALE_CAMERA_TIMEOUT = 1.2

local holdStatesByPlayer: { [Player]: HoldState } = {}
local objectLockByInteractable: { [Instance]: Player } = {}

local remotesFolder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = REMOTE_FOLDER_NAME
	remotesFolder.Parent = ReplicatedStorage
end

local pickupRemote = remotesFolder:FindFirstChild(REMOTE_NAME) :: RemoteEvent?
if not pickupRemote then
	pickupRemote = Instance.new("RemoteEvent")
	pickupRemote.Name = REMOTE_NAME
	pickupRemote.Parent = remotesFolder
end
pickupRemote = pickupRemote :: RemoteEvent

local function getCharacterPart(character: Model, partName: string): BasePart?
	local part = character:FindFirstChild(partName)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function getCharacterHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return getCharacterPart(character, "Head")
end

local function sendHoldState(player: Player, isHolding: boolean, targetRoot: InteractableRoot?)
	pickupRemote:FireClient(player, {
		Action = "HoldState",
		Holding = isHolding,
		Target = targetRoot,
	})
end

local function sanitizeCameraCFrame(player: Player, rawCameraCFrame: any): CFrame
	local head = getCharacterHead(player)
	local fallback = if head then head.CFrame else CFrame.identity

	if typeof(rawCameraCFrame) ~= "CFrame" then
		return fallback
	end

	local lookVector = rawCameraCFrame.LookVector
	if lookVector.Magnitude < 0.95 then
		lookVector = fallback.LookVector
	end

	local upVector = rawCameraCFrame.UpVector
	if upVector.Magnitude < 0.95 then
		upVector = Vector3.yAxis
	end

	return CFrame.lookAt(fallback.Position, fallback.Position + lookVector, upVector)
end

local function releaseHeldObject(player: Player)
	local currentState = holdStatesByPlayer[player]
	if not currentState then
		return
	end

	if objectLockByInteractable[currentState.TargetRoot] == player then
		objectLockByInteractable[currentState.TargetRoot] = nil
	end

	PhysicsPickupUtil.SetNetworkOwner(currentState.TargetRoot, nil)
	PhysicsPickupUtil.CleanupHoldConstraints(currentState.Bundle)

	holdStatesByPlayer[player] = nil
	sendHoldState(player, false, nil)
end

local function getRootSize(targetRoot: InteractableRoot): Vector3
	if targetRoot:IsA("BasePart") then
		return targetRoot.Size
	end

	local _, size = targetRoot:GetBoundingBox()
	return size
end

local function getHoldDistance(targetRoot: InteractableRoot): number
	local size = getRootSize(targetRoot)
	local sizeDrivenDistance = math.max(size.Magnitude * 0.35, DEFAULT_HOLD_DISTANCE)
	return math.clamp(sizeDrivenDistance, MIN_HOLD_DISTANCE, MAX_HOLD_DISTANCE_FROM_SIZE)
end

local function canPickupTarget(
	player: Player,
	requestedInstance: Instance,
	clientRayOrigin: any,
	clientRayDirection: any
): (boolean, InteractableRoot?, BasePart?, string?)
	local character = player.Character
	local head = if character then getCharacterPart(character, "Head") else nil
	if not character or not head then
		return false, nil, nil, "missing character"
	end

	local targetRoot = PhysicsPickupUtil.FindInteractableRoot(requestedInstance)
	if not targetRoot then
		return false, nil, nil, "not interactable"
	end

	if targetRoot:IsDescendantOf(character) then
		return false, nil, nil, "target belongs to character"
	end

	local existingLock = objectLockByInteractable[targetRoot]
	if existingLock and existingLock ~= player then
		return false, nil, nil, "already held"
	end

	local rootPart = PhysicsPickupUtil.ResolveRootPart(targetRoot)
	if not rootPart then
		return false, nil, nil, "no root part"
	end

	if rootPart.Anchored then
		return false, nil, nil, "target anchored"
	end

	local targetCenter = PhysicsPickupUtil.GetBoundingCenter(targetRoot)
	local directDistance = (head.Position - targetCenter).Magnitude
	if directDistance > MAX_PICKUP_DISTANCE then
		return false, nil, nil, "out of range"
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local direction = targetCenter - head.Position
	local raycastResult = Workspace:Raycast(head.Position, direction, raycastParams)
	if raycastResult and not PhysicsPickupUtil.InstanceBelongsToRoot(raycastResult.Instance, targetRoot) then
		return false, nil, nil, "obstructed line of sight"
	end

	if typeof(clientRayOrigin) ~= "Vector3" or typeof(clientRayDirection) ~= "Vector3" then
		return false, nil, nil, "missing client raycast data"
	end

	if clientRayDirection.Magnitude > MAX_CLIENT_RAY_DISTANCE then
		return false, nil, nil, "client raycast too long"
	end

	if (clientRayOrigin - head.Position).Magnitude > 6 then
		return false, nil, nil, "invalid ray origin"
	end

	local clientRaycastResult = Workspace:Raycast(clientRayOrigin, clientRayDirection, raycastParams)
	if not clientRaycastResult then
		return false, nil, nil, "client ray did not hit target"
	end

	if not PhysicsPickupUtil.InstanceBelongsToRoot(clientRaycastResult.Instance, targetRoot) then
		return false, nil, nil, "client ray hit wrong target"
	end

	return true, targetRoot, rootPart, nil
end

local function beginHoldingObject(player: Player, targetRoot: InteractableRoot, rootPart: BasePart, cameraCFrame: CFrame)
	releaseHeldObject(player)

	local character = player.Character
	if not character then
		return
	end

	local holdDistance = getHoldDistance(targetRoot)
	local rotationOffset = PhysicsPickupUtil.CalculateInitialRotationOffset(cameraCFrame, rootPart)

	for _, part in PhysicsPickupUtil.GetBaseParts(targetRoot) do
		if not part.Anchored then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end

	local bundle = PhysicsPickupUtil.CreateHoldConstraints(targetRoot, rootPart, player.UserId)
	bundle.CollisionConstraints = PhysicsPickupUtil.CreateNoCollisionConstraints(targetRoot, character, bundle.RuntimeFolder)

	PhysicsPickupUtil.SetNetworkOwner(targetRoot, player)

	local initialCFrame = PhysicsPickupUtil.ComposeHoldCFrame(cameraCFrame, holdDistance, rotationOffset)
	bundle.AnchorPart.CFrame = initialCFrame

	holdStatesByPlayer[player] = {
		TargetRoot = targetRoot,
		RootPart = rootPart,
		Bundle = bundle,
		RotationOffset = rotationOffset,
		LastCameraCFrame = cameraCFrame,
		HoldDistance = holdDistance,
		LastUpdate = os.clock(),
	}
	objectLockByInteractable[targetRoot] = player

	sendHoldState(player, true, targetRoot)
end

local function processPickupRequest(player: Player, payload: { [string]: any })
	local requestedTarget = payload.Target
	if typeof(requestedTarget) ~= "Instance" then
		return
	end

	local canPickup, targetRoot, rootPart = canPickupTarget(
		player,
		requestedTarget,
		payload.RayOrigin,
		payload.RayDirection
	)
	if not canPickup or not targetRoot or not rootPart then
		return
	end

	local cameraCFrame = sanitizeCameraCFrame(player, payload.CameraCFrame)
	beginHoldingObject(player, targetRoot, rootPart, cameraCFrame)
end

local function processUpdateRequest(player: Player, payload: { [string]: any })
	local holdState = holdStatesByPlayer[player]
	if not holdState then
		return
	end

	holdState.LastCameraCFrame = sanitizeCameraCFrame(player, payload.CameraCFrame)
	holdState.LastUpdate = os.clock()
end

local function processRotateRequest(player: Player, payload: { [string]: any })
	local holdState = holdStatesByPlayer[player]
	if not holdState then
		return
	end

	local delta = payload.Delta
	if typeof(delta) ~= "Vector2" then
		return
	end

	local clampedX = math.clamp(delta.X, -MAX_ROTATION_DELTA, MAX_ROTATION_DELTA)
	local clampedY = math.clamp(delta.Y, -MAX_ROTATION_DELTA, MAX_ROTATION_DELTA)

	local yaw = math.rad(-clampedX * ROTATION_DEGREES_PER_PIXEL)
	local pitch = math.rad(-clampedY * ROTATION_DEGREES_PER_PIXEL)

	holdState.RotationOffset = CFrame.Angles(pitch, yaw, 0) * holdState.RotationOffset
	holdState.LastUpdate = os.clock()
end

pickupRemote.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.Action
	if action == "RequestPickup" then
		processPickupRequest(player, payload)
	elseif action == "UpdateHold" then
		processUpdateRequest(player, payload)
	elseif action == "Rotate" then
		processRotateRequest(player, payload)
	elseif action == "Drop" then
		releaseHeldObject(player)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	releaseHeldObject(player)
end)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterRemoving:Connect(function()
		releaseHeldObject(player)
	end)
end)

for _, player in Players:GetPlayers() do
	player.CharacterRemoving:Connect(function()
		releaseHeldObject(player)
	end)
end

RunService.Heartbeat:Connect(function()
	for player, holdState in holdStatesByPlayer do
		if not holdState.RootPart.Parent then
			releaseHeldObject(player)
			continue
		end
		if holdState.RootPart.Anchored then
			releaseHeldObject(player)
			continue
		end

		local character = player.Character
		local head = if character then getCharacterPart(character, "Head") else nil
		if not character or not head then
			releaseHeldObject(player)
			continue
		end

		if os.clock() - holdState.LastUpdate > STALE_CAMERA_TIMEOUT then
			holdState.LastCameraCFrame = sanitizeCameraCFrame(player, nil)
		end

		holdState.Bundle.AnchorPart.CFrame = PhysicsPickupUtil.ComposeHoldCFrame(
			holdState.LastCameraCFrame,
			holdState.HoldDistance,
			holdState.RotationOffset
		)

		local distanceFromHead = (PhysicsPickupUtil.GetBoundingCenter(holdState.TargetRoot) - head.Position).Magnitude
		if distanceFromHead > MAX_HOLD_DISTANCE then
			releaseHeldObject(player)
		end
	end
end)
