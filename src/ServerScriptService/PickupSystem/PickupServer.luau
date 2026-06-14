--!strict
--[[
	PickupServer
	Authoritative server controller for object pickup, hold constraints,
	network ownership, and anti-exploit validation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupConfig = require(ReplicatedStorage.Shared.PickupConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PhysicsUtility = require(ReplicatedStorage.PickupSystem.PhysicsUtility)

type InteractableRoot = PhysicsUtility.InteractableRoot
type HoldConstraintSet = PhysicsUtility.HoldConstraintSet

type PlayerHoldState = {
	object: InteractableRoot,
	holdTarget: BasePart,
	constraints: HoldConstraintSet,
	originalCanCollide: { [BasePart]: boolean },
}

local PickupServer = {}

local playerHoldStates: { [Player]: PlayerHoldState } = {}

local function getCharacterRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getServerRaycastParams(player: Player): RaycastParams
	return PhysicsUtility.buildRaycastParams(player.Character)
end

local function validatePickupRequest(
	player: Player,
	targetInstance: Instance,
	clientHitPosition: Vector3
): (boolean, InteractableRoot?, string?)
	if typeof(clientHitPosition) ~= "Vector3" then
		return false, nil, "Invalid hit position"
	end

	if not targetInstance or not targetInstance:IsDescendantOf(workspace) then
		return false, nil, "Invalid target"
	end

	if playerHoldStates[player] then
		return false, nil, "Already holding an object"
	end

	local root = PhysicsUtility.getInteractableRoot(targetInstance)
	if not root then
		return false, nil, "Target is not interactable"
	end

	local characterRoot = getCharacterRootPart(player)
	if not characterRoot then
		return false, nil, "Character not ready"
	end

	local objectPosition = PhysicsUtility.getObjectWorldPosition(root)
	local distanceToObject = (objectPosition - characterRoot.Position).Magnitude
	if distanceToObject > PickupConfig.MAX_PICKUP_DISTANCE then
		return false, nil, "Target too far away"
	end

	local origin = characterRoot.Position
	local toHit = clientHitPosition - origin
	if toHit.Magnitude < 0.01 then
		return false, nil, "Invalid ray direction"
	end

	local direction = toHit.Unit * math.min(toHit.Magnitude, PickupConfig.MAX_PICKUP_DISTANCE)
	local raycastResult = workspace:Raycast(origin, direction, getServerRaycastParams(player))
	if not raycastResult then
		return false, nil, "No line of sight"
	end

	local hitRoot = PhysicsUtility.getInteractableRoot(raycastResult.Instance)
	if hitRoot ~= root then
		return false, nil, "Line of sight mismatch"
	end

	local hitDistance = (raycastResult.Position - origin).Magnitude
	if hitDistance > PickupConfig.MAX_PICKUP_DISTANCE then
		return false, nil, "Raycast distance exceeded"
	end

	return true, root, nil
end

local function storeOriginalCollision(root: InteractableRoot): { [BasePart]: boolean }
	local stored: { [BasePart]: boolean } = {}
	for _, part in PhysicsUtility.getAllBaseParts(root) do
		stored[part] = part.CanCollide
	end
	return stored
end

local function releaseObject(player: Player, applyDropImpulse: boolean): ()
	local state = playerHoldStates[player]
	if not state then
		return
	end

	playerHoldStates[player] = nil

	PhysicsUtility.destroyHoldConstraints(state.constraints)
	PhysicsUtility.restoreDefaultCollisionGroup(state.object)
	PhysicsUtility.setNetworkOwnership(state.object, nil)

	for part, canCollide in state.originalCanCollide do
		if part.Parent then
			part.CanCollide = canCollide
		end
	end

	if applyDropImpulse then
		local character = player.Character
		local rootPart = state.constraints.rootPart
		if character and rootPart.Parent then
			local head = character:FindFirstChild("Head") :: BasePart?
			if head then
				rootPart.AssemblyLinearVelocity = head.CFrame.LookVector * 8
			end
		end
	end

	state.holdTarget:Destroy()
	player:SetAttribute("HoldingPickup", false)

	Remotes.PickupResult:FireClient(player, false, nil)
end

local function onPickupRequest(player: Player, targetInstance: Instance, clientHitPosition: Vector3): ()
	local isValid, root, reason = validatePickupRequest(player, targetInstance, clientHitPosition)
	if not isValid or not root then
		Remotes.PickupResult:FireClient(player, false, reason)
		return
	end

	local character = player.Character
	if character then
		PhysicsUtility.setCharacterCollisionGroup(character)
	end

	local rootPart = PhysicsUtility.prepareForPickup(root)
	local holdAnchorCFrame = PhysicsUtility.getHoldAnchorCFrame(root)
	local holdTarget = PhysicsUtility.createHoldTarget(player)

	local head = if character then character:FindFirstChild("Head") :: BasePart? else nil
	local characterRoot = getCharacterRootPart(player)
	if head then
		holdTarget.CFrame = head.CFrame * CFrame.new(0, PickupConfig.HOLD_VERTICAL_OFFSET, -PickupConfig.HOLD_DISTANCE)
	elseif characterRoot then
		holdTarget.CFrame = characterRoot.CFrame * CFrame.new(0, 0, -PickupConfig.HOLD_DISTANCE)
	end

	local constraints = PhysicsUtility.createHoldConstraints(rootPart, holdTarget, holdAnchorCFrame)

	PhysicsUtility.setHeldCollisionGroup(root)
	PhysicsUtility.setNetworkOwnership(root, player)
	holdTarget:SetNetworkOwner(player)

	playerHoldStates[player] = {
		object = root,
		holdTarget = holdTarget,
		constraints = constraints,
		originalCanCollide = storeOriginalCollision(root),
	}

	player:SetAttribute("HoldingPickup", true)
	Remotes.PickupResult:FireClient(player, true, root)
end

local function onDropRequest(player: Player): ()
	releaseObject(player, true)
end

local function onPlayerRemoving(player: Player): ()
	releaseObject(player, false)
end

local function onCharacterAdded(player: Player, character: Model): ()
	PhysicsUtility.setCharacterCollisionGroup(character)

	if playerHoldStates[player] then
		releaseObject(player, false)
	end
end

function PickupServer.init(): ()
	PhysicsUtility.ensureCollisionGroups()

	Remotes.PickupRequest.OnServerEvent:Connect(onPickupRequest)
	Remotes.DropRequest.OnServerEvent:Connect(onDropRequest)

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)

		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end)

	for _, player in Players:GetPlayers() do
		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end
end

return PickupServer
