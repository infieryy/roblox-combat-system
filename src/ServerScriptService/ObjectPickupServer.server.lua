local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PhysicsPickupUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PhysicsPickupUtil"))

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_EVENT_NAME = "ObjectPickupRemote"

local MAX_PICKUP_DISTANCE = 12
local MAX_CAMERA_TO_HEAD_DISTANCE = 6
local MAX_HOLD_FROM_HEAD_DISTANCE = 14
local HOLD_DISTANCE = 4
local HOLD_HEIGHT = -0.35
local MAX_PITCH = 80

type ConstraintBundle = PhysicsPickupUtil.ConstraintBundle

type HoldState = {
	target: Instance,
	rootPart: BasePart,
	constraints: ConstraintBundle,
	rotationYaw: number,
	rotationPitch: number,
	ancestryConnection: RBXScriptConnection?,
}

local holdStates: { [Player]: HoldState } = {}
local lockedTargets: { [Instance]: Player } = {}

local remotesFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = REMOTES_FOLDER_NAME
	remotesFolder.Parent = ReplicatedStorage
end

local pickupRemote = remotesFolder:FindFirstChild(REMOTE_EVENT_NAME) :: RemoteEvent?
if not pickupRemote then
	pickupRemote = Instance.new("RemoteEvent")
	pickupRemote.Name = REMOTE_EVENT_NAME
	pickupRemote.Parent = remotesFolder
end

local function pushPickupState(player: Player, isHolding: boolean)
	pickupRemote:FireClient(player, "PickupState", {
		isHolding = isHolding,
	})
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("Head") :: BasePart?
end

local function getInteractionOrigin(player: Player): Vector3?
	local head = getHead(player)
	if head then
		return head.Position
	end

	local rootPart = getCharacterRoot(player)
	if rootPart then
		return rootPart.Position
	end

	return nil
end

local function releaseHeldObject(player: Player)
	local currentState = holdStates[player]
	if not currentState then
		return
	end

	if currentState.ancestryConnection then
		currentState.ancestryConnection:Disconnect()
	end

	PhysicsPickupUtil.setNetworkOwner(currentState.target, nil)
	PhysicsPickupUtil.destroyConstraintBundle(currentState.constraints)

	lockedTargets[currentState.target] = nil
	holdStates[player] = nil
	pushPickupState(player, false)
end

local function validateRaycastTarget(player: Player, requestTarget: Instance, rayOrigin: Vector3, rayDirection: Vector3): (boolean, string, Instance?, BasePart?)
	if rayDirection.Magnitude < 1e-3 then
		return false, "Ray direction too small", nil, nil
	end

	local character = player.Character
	if not character then
		return false, "Missing character", nil, nil
	end

	local interactable = PhysicsPickupUtil.findInteractableFromHit(requestTarget)
	if not interactable then
		return false, "Not interactable", nil, nil
	end

	if interactable:IsDescendantOf(character) then
		return false, "Cannot pick up own character", nil, nil
	end

	if lockedTargets[interactable] and lockedTargets[interactable] ~= player then
		return false, "Target already held", nil, nil
	end

	local rootPart = PhysicsPickupUtil.getRootPart(interactable)
	if not rootPart then
		return false, "No root part", nil, nil
	end

	if rootPart.Anchored then
		return false, "Target is anchored", nil, nil
	end

	local serverOrigin = getInteractionOrigin(player)
	if not serverOrigin then
		return false, "No server origin", nil, nil
	end

	if (rayOrigin - serverOrigin).Magnitude > MAX_CAMERA_TO_HEAD_DISTANCE then
		return false, "Camera origin out of range", nil, nil
	end

	if (rootPart.Position - serverOrigin).Magnitude > MAX_PICKUP_DISTANCE then
		return false, "Target too far", nil, nil
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.IgnoreWater = true

	local castDirection = rayDirection.Unit * MAX_PICKUP_DISTANCE
	local rayResult = workspace:Raycast(rayOrigin, castDirection, rayParams)
	if not rayResult then
		return false, "Raycast miss", nil, nil
	end

	if not rayResult.Instance:IsDescendantOf(interactable) then
		return false, "Raycast blocked", nil, nil
	end

	return true, "OK", interactable, rootPart
end

local function updateAnchorForState(player: Player, state: HoldState, cameraCFrame: CFrame, rotationDelta: Vector2?)
	local serverOrigin = getInteractionOrigin(player)
	if not serverOrigin then
		releaseHeldObject(player)
		return
	end

	if (cameraCFrame.Position - serverOrigin).Magnitude > MAX_CAMERA_TO_HEAD_DISTANCE then
		return
	end

	if rotationDelta then
		state.rotationYaw += rotationDelta.X
		state.rotationPitch = math.clamp(state.rotationPitch + rotationDelta.Y, -MAX_PITCH, MAX_PITCH)
	end

	local rotation = CFrame.Angles(math.rad(state.rotationPitch), math.rad(state.rotationYaw), 0)
	local desiredAnchor = PhysicsPickupUtil.computeAnchorCFrame(cameraCFrame, HOLD_DISTANCE, HOLD_HEIGHT, rotation)
	if (desiredAnchor.Position - serverOrigin).Magnitude > MAX_HOLD_FROM_HEAD_DISTANCE then
		return
	end

	state.constraints.anchorPart.CFrame = desiredAnchor
end

pickupRemote.OnServerEvent:Connect(function(player: Player, action: string, payload)
	if action == "Drop" then
		releaseHeldObject(player)
		return
	end

	if action == "Pickup" then
		if type(payload) ~= "table" then
			return
		end

		local target = payload.target
		local rayOrigin = payload.rayOrigin
		local rayDirection = payload.rayDirection
		local cameraCFrame = payload.cameraCFrame

		if typeof(target) ~= "Instance" or typeof(rayOrigin) ~= "Vector3" or typeof(rayDirection) ~= "Vector3" then
			return
		end

		if holdStates[player] then
			releaseHeldObject(player)
		end

		local success, _, interactable, rootPart = validateRaycastTarget(player, target, rayOrigin, rayDirection)
		if not success or not interactable or not rootPart then
			pushPickupState(player, false)
			return
		end

		local character = player.Character
		if not character then
			return
		end

		PhysicsPickupUtil.resetAssemblyVelocity(interactable)
		local bundle = PhysicsPickupUtil.createConstraintBundle(interactable, rootPart)
		bundle.noCollisionConstraints = PhysicsPickupUtil.setNoCollisionWithCharacter(interactable, character)
		PhysicsPickupUtil.setNetworkOwner(interactable, player)

		local state: HoldState = {
			target = interactable,
			rootPart = rootPart,
			constraints = bundle,
			rotationYaw = 0,
			rotationPitch = 0,
			ancestryConnection = nil,
		}

		state.ancestryConnection = interactable.AncestryChanged:Connect(function(_, parent)
			if not parent then
				releaseHeldObject(player)
			end
		end)

		holdStates[player] = state
		lockedTargets[interactable] = player

		local initialCamera = if typeof(cameraCFrame) == "CFrame" then cameraCFrame else CFrame.new(rayOrigin, rayOrigin + rayDirection)
		updateAnchorForState(player, state, initialCamera, nil)
		pushPickupState(player, true)
		return
	end

	if action == "UpdateHold" then
		local state = holdStates[player]
		if not state then
			return
		end

		if type(payload) ~= "table" then
			return
		end

		local cameraCFrame = payload.cameraCFrame
		if typeof(cameraCFrame) ~= "CFrame" then
			return
		end

		local rotationDelta = nil
		if typeof(payload.rotationDelta) == "Vector2" then
			rotationDelta = payload.rotationDelta
		end

		updateAnchorForState(player, state, cameraCFrame, rotationDelta)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	releaseHeldObject(player)
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterRemoving:Connect(function()
		releaseHeldObject(player)
	end)
end)
