--!strict
--[[
	PickupServer
	------------
	Authoritative controller for the first-person pickup system.

	Responsibilities:
	  * Validate every pickup request (tag/attribute, reachability, ownership).
	  * Transfer network ownership to the holder for zero-lag local physics.
	  * Build the AlignPosition / AlignOrientation drag rig via PhysicsUtil.
	  * Apply the holder-streamed goal each update, clamped to a safe radius so
	    a tampered client cannot fling objects across the map.
	  * Watchdog + lifecycle cleanup (drop on death, leave, or object removal).

	One object per player. State lives in `sessions` keyed by Player.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupSystem = ReplicatedStorage:WaitForChild("PickupSystem")
local Config = require(PickupSystem:WaitForChild("Config"))
local PhysicsUtil = require(PickupSystem:WaitForChild("PhysicsUtil"))
local Remotes = require(PickupSystem:WaitForChild("Remotes"))

type Session = {
	object: Instance,
	handle: BasePart,
	rig: PhysicsUtil.HoldRig,
	welds: { WeldConstraint },
	noCollisions: { NoCollisionConstraint },
}

local sessions: { [Player]: Session } = {}

-- Attributes stamped on a held object so other systems (and re-entrancy
-- guards) can tell it is currently in someone's hands.
local ATTR_HELD = "PickupHeld"
local ATTR_HOLDER = "PickupHolderUserId"

local function isInteractable(object: Instance): boolean
	if CollectionService:HasTag(object, Config.Tag) then
		return true
	end
	return object:GetAttribute(Config.Attribute) == true
end

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAnchored(object: Instance): boolean
	for _, part in ipairs(PhysicsUtil.getParts(object)) do
		if part.Anchored then
			return true
		end
	end
	return false
end

local function dropObject(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil

	PhysicsUtil.destroyAll({
		session.rig.AlignPosition,
		session.rig.AlignOrientation,
		session.rig.Attachment,
	})
	PhysicsUtil.destroyAll(session.noCollisions)
	PhysicsUtil.destroyAll(session.welds)

	if session.object.Parent then
		session.object:SetAttribute(ATTR_HELD, nil)
		session.object:SetAttribute(ATTR_HOLDER, nil)
	end

	-- Return physics authority to the engine's automatic assignment.
	if session.handle.Parent then
		PhysicsUtil.setNetworkOwner(session.handle, nil)
	end

	Remotes.HoldEnded:FireClient(player, session.object)
end

local function onPickupRequest(player: Player, object: unknown, _hitPosition: unknown)
	-- One object at a time.
	if sessions[player] then
		return
	end

	if typeof(object) ~= "Instance" then
		return
	end
	local instance = object :: Instance

	if not instance.Parent or not instance:IsDescendantOf(workspace) then
		return
	end
	if not isInteractable(instance) then
		return
	end
	if instance:GetAttribute(ATTR_HELD) then
		return
	end

	local handle = PhysicsUtil.getHandle(instance)
	if not handle then
		return
	end
	if isAnchored(instance) then
		return
	end

	-- Server-side reachability check (anti-exploit). Measured from the head to
	-- the object's bounding sphere (so large meshes aren't unfairly rejected),
	-- with a latency margin.
	local head = getHead(player)
	if not head then
		return
	end
	local centreCFrame, size = PhysicsUtil.getBoundingBox(instance)
	local boundingRadius = size.Magnitude / 2
	local distance = (centreCFrame.Position - head.Position).Magnitude - boundingRadius
	if distance > Config.MaxPickupDistance * Config.ServerDistanceSlack then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	-- Build the rig. Order matters: weld first (so mass reflects the whole
	-- assembly), then ownership, then constraints + collision filtering.
	local welds = PhysicsUtil.ensureWelded(instance, handle)
	PhysicsUtil.setNetworkOwner(handle, player)

	local mass = PhysicsUtil.getAssemblyMass(handle)
	local rig = PhysicsUtil.createHoldRig(handle, centreCFrame.Position, mass)
	local noCollisions = PhysicsUtil.disableCharacterCollisions(instance, character)

	instance:SetAttribute(ATTR_HELD, true)
	instance:SetAttribute(ATTR_HOLDER, player.UserId)

	sessions[player] = {
		object = instance,
		handle = handle,
		rig = rig,
		welds = welds,
		noCollisions = noCollisions,
	}

	Remotes.HoldStarted:FireClient(player, instance)
end

local function onUpdateGoal(player: Player, position: unknown, cframe: unknown)
	local session = sessions[player]
	if not session then
		return
	end
	if typeof(position) ~= "Vector3" or typeof(cframe) ~= "CFrame" then
		return
	end

	local goalPosition = position :: Vector3
	local goalCFrame = cframe :: CFrame

	-- Clamp the requested position to a safe radius around the player's head so
	-- a modified client cannot drive the object arbitrarily far.
	local head = getHead(player)
	if head then
		local offset = goalPosition - head.Position
		if offset.Magnitude > Config.MaxHoldDistance then
			goalPosition = head.Position + offset.Unit * Config.MaxHoldDistance
		end
	end

	session.rig.AlignPosition.Position = goalPosition
	session.rig.AlignOrientation.CFrame = goalCFrame.Rotation
end

local function onDropRequest(player: Player)
	dropObject(player)
end

-- Watchdog: drop anything that has drifted too far or whose object/character
-- has gone away. Runs server-side and is independent of client cooperation.
local function onHeartbeat()
	for player, session in pairs(sessions) do
		if not session.object.Parent or not session.handle.Parent then
			dropObject(player)
			continue
		end

		local head = getHead(player)
		if not head then
			dropObject(player)
			continue
		end

		local distance = (session.handle.Position - head.Position).Magnitude
		if distance > Config.MaxHoldDistance * Config.HoldBreakMultiplier then
			dropObject(player)
		end
	end
end

local function onPlayerRemoving(player: Player)
	dropObject(player)
end

local function onCharacterAdded(player: Player, character: Model)
	-- A respawn (or any new character) invalidates the current hold.
	dropObject(player)

	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			dropObject(player)
		end)
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

Remotes.PickupRequest.OnServerEvent:Connect(onPickupRequest)
Remotes.DropRequest.OnServerEvent:Connect(onDropRequest)
Remotes.UpdateGoal.OnServerEvent:Connect(onUpdateGoal)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

RunService.Heartbeat:Connect(onHeartbeat)
