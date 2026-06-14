--!strict

--[[
	Server-authoritative pickup controller.
	Validates raycasts, manages network ownership, constraints, and collision isolation.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PickupSystem.Config)
local PhysicsUtility = require(ReplicatedStorage.PickupSystem.PhysicsUtility)
local Remotes = require(ReplicatedStorage.PickupSystem.Remotes)

type HeldRecord = {
	player: Player,
	model: Model,
	modelInfo: PhysicsUtility.PickupModelInfo,
	holdPart: BasePart,
	constraintSet: PhysicsUtility.HoldConstraintSet,
	inspectionRotation: CFrame,
}

local heldByPlayer: { [Player]: HeldRecord } = {}
local heldModels: { [Model]: Player } = {}

local pickupRequest = Remotes.getPickupRequest()
local dropRequest = Remotes.getDropRequest()
local rotateUpdate = Remotes.getRotateUpdate()
local holdState = Remotes.getHoldState()

PhysicsUtility.ensureCollisionGroups(Config.COLLISION_GROUP_HELD, Config.COLLISION_GROUP_CHARACTER)

local function isPickupable(instance: Instance): boolean
	if CollectionService:HasTag(instance, Config.PICKUP_TAG) then
		return true
	end

	local model = PhysicsUtility.resolvePickupModel(instance, false)
	if not model then
		if (instance:IsA("BasePart") or instance:IsA("MeshPart")) and (
			CollectionService:HasTag(instance, Config.PICKUP_TAG)
			or instance:GetAttribute(Config.PICKUP_ATTRIBUTE) == true
		) then
			return true
		end
		return false
	end

	if model:GetAttribute(Config.PICKUP_ATTRIBUTE) == true then
		return true
	end

	if CollectionService:HasTag(model, Config.PICKUP_TAG) then
		return true
	end

	return false
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getValidatedCameraCFrame(player: Player, clientCameraCFrame: CFrame): CFrame?
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	local head = player.Character and player.Character:FindFirstChild("Head") :: BasePart?
	local referencePosition = if head then head.Position else rootPart.Position

	if (clientCameraCFrame.Position - referencePosition).Magnitude > Config.CAMERA_POSITION_TOLERANCE then
		return nil
	end

	return clientCameraCFrame
end

local function raycastMatchesTarget(
	origin: Vector3,
	direction: Vector3,
	targetModel: Model,
	excludeCharacter: Model?
): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local excludeList: { Instance } = {}
	if excludeCharacter then
		table.insert(excludeList, excludeCharacter)
	end
	params.FilterDescendantsInstances = excludeList

	local result = workspace:Raycast(origin, direction, params)
	if not result then
		return false
	end

	local hitInstance = result.Instance
	if hitInstance:IsDescendantOf(targetModel) then
		return true
	end

	if (result.Position - origin).Magnitude <= Config.RAYCAST_TOLERANCE then
		local pivot = targetModel:GetPivot().Position
		if (pivot - result.Position).Magnitude <= Config.RAYCAST_TOLERANCE * 2 then
			return true
		end
	end

	return false
end

local function validatePickupRequest(
	player: Player,
	targetInstance: Instance,
	hitPosition: Vector3,
	clientCameraCFrame: CFrame
): Model?
	if heldByPlayer[player] then
		return nil
	end

	if not targetInstance or not targetInstance:IsDescendantOf(workspace) then
		return nil
	end

	if not isPickupable(targetInstance) then
		return nil
	end

	local model = PhysicsUtility.resolvePickupModel(targetInstance, true)
	if not model or heldModels[model] then
		return nil
	end

	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	if (hitPosition - rootPart.Position).Magnitude > Config.MAX_PICKUP_DISTANCE then
		return nil
	end

	local validatedCamera = getValidatedCameraCFrame(player, clientCameraCFrame)
	if not validatedCamera then
		return nil
	end

	local rayDirection = validatedCamera.LookVector * Config.MAX_PICKUP_DISTANCE
	if not raycastMatchesTarget(validatedCamera.Position, rayDirection, model, player.Character) then
		return nil
	end

	return model
end

local function setHoldPartNetworkOwner(player: Player, holdPart: BasePart)
	pcall(function()
		holdPart:SetNetworkOwner(player)
	end)
end

local function setModelNetworkOwner(player: Player, model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			pcall(function()
				(descendant :: BasePart):SetNetworkOwner(player)
			end)
		end
	end
end

local function clearModelNetworkOwner(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			pcall(function()
				(descendant :: BasePart):SetNetworkOwnershipAuto()
			end)
		end
	end
end

local function releaseHeldObject(player: Player, applyDropImpulse: boolean)
	local record = heldByPlayer[player]
	if not record then
		return
	end

	heldByPlayer[player] = nil
	heldModels[record.model] = nil

	PhysicsUtility.destroyHoldConstraints(record.constraintSet)

	if record.holdPart and record.holdPart.Parent then
		record.holdPart:Destroy()
	end

	PhysicsUtility.setModelCollisionGroup(record.model, "Default")
	clearModelNetworkOwner(record.model)

	if applyDropImpulse then
		local rootPart = record.modelInfo.rootPart
		if rootPart and rootPart.Parent then
			local impulse = record.modelInfo.rootPart.CFrame.LookVector * rootPart.AssemblyMass * 4
			rootPart:ApplyImpulse(impulse)
		end
	end

	holdState:FireClient(player, nil)
end

local function beginHold(player: Player, model: Model)
	local character = player.Character
	if not character then
		return
	end

	local modelInfo = PhysicsUtility.prepareModelForPickup(model)
	if not modelInfo then
		return
	end

	local holdPart = PhysicsUtility.createHoldPart(character)
	if not holdPart then
		return
	end

	PhysicsUtility.setCharacterCollisionGroup(character, Config.COLLISION_GROUP_CHARACTER)
	PhysicsUtility.setModelCollisionGroup(model, Config.COLLISION_GROUP_HELD)

	local constraintSet = PhysicsUtility.createHoldConstraints(
		modelInfo,
		holdPart,
		Config.ALIGN_POSITION_RESPONSIVENESS,
		Config.ALIGN_POSITION_MAX_FORCE,
		Config.ALIGN_POSITION_MAX_VELOCITY,
		Config.ALIGN_ORIENTATION_RESPONSIVENESS,
		Config.ALIGN_ORIENTATION_MAX_TORQUE,
		Config.ALIGN_ORIENTATION_MAX_ANGULAR_VELOCITY
	)

	constraintSet.noCollisionConstraints = PhysicsUtility.createNoCollisionWithCharacter(model, character)

	setModelNetworkOwner(player, model)
	setHoldPartNetworkOwner(player, holdPart)

	local record: HeldRecord = {
		player = player,
		model = model,
		modelInfo = modelInfo,
		holdPart = holdPart,
		constraintSet = constraintSet,
		inspectionRotation = CFrame.identity,
	}

	heldByPlayer[player] = record
	heldModels[model] = player

	holdState:FireClient(player, model)
end

pickupRequest.OnServerEvent:Connect(function(player: Player, targetInstance: Instance, hitPosition: Vector3, clientCameraCFrame: CFrame)
	if typeof(hitPosition) ~= "Vector3" or typeof(clientCameraCFrame) ~= "CFrame" then
		return
	end

	local model = validatePickupRequest(player, targetInstance, hitPosition, clientCameraCFrame)
	if model then
		beginHold(player, model)
	end
end)

dropRequest.OnServerEvent:Connect(function(player: Player, applyDropImpulse: boolean?)
	releaseHeldObject(player, applyDropImpulse ~= false)
end)

rotateUpdate.OnServerEvent:Connect(function(player: Player, inspectionRotation: CFrame)
	local record = heldByPlayer[player]
	if not record or typeof(inspectionRotation) ~= "CFrame" then
		return
	end

	record.inspectionRotation = inspectionRotation
end)

RunService.Heartbeat:Connect(function()
	for player, record in heldByPlayer do
		local character = player.Character
		local rootPart = getCharacterRoot(player)
		if not character or not rootPart or not record.model.Parent or not record.holdPart.Parent then
			releaseHeldObject(player, false)
			continue
		end

		local holdDistance = (record.holdPart.Position - rootPart.Position).Magnitude
		if holdDistance > Config.MAX_HOLD_DISTANCE then
			releaseHeldObject(player, false)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	releaseHeldObject(player, false)
end)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		PhysicsUtility.setCharacterCollisionGroup(character, Config.COLLISION_GROUP_CHARACTER)

		if heldByPlayer[player] then
			releaseHeldObject(player, false)
		end
	end)
end)

for _, player in Players:GetPlayers() do
	if player.Character then
		PhysicsUtility.setCharacterCollisionGroup(player.Character, Config.COLLISION_GROUP_CHARACTER)
	end
end
