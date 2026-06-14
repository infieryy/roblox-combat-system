--!strict
--[[
	PickupService (ModuleScript)
	----------------------------
	The authoritative brain of the system. It:
	  * registers the collision groups,
	  * validates every pickup request (distance + ownership + mass),
	  * hands network ownership of the held assembly to the player so physics are
	    simulated locally and feel completely lag-free,
	  * builds the AlignPosition / AlignOrientation rig via PhysicsUtil,
	  * disables collisions between held objects and characters (but NOT walls),
	  * runs a leash loop that force-drops anything that travels too far,
	  * cleans up on drop, death and disconnect.

	Security model:
	  The client only ever *asks* to pick up an instance it is looking at. The
	  server re-derives the interactable, re-checks the distance with its own
	  data, verifies the object is free, and only then grants the request. After
	  that the client owns the physics, but the leash loop keeps it honest.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")

local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PhysicsUtil = require(Shared:WaitForChild("PhysicsUtil"))
local Interactable = require(Shared:WaitForChild("Interactable"))

local HELD_ATTRIBUTE = "PickupHeldBy"

type HeldData = {
	interactable: Instance,
	primary: BasePart,
	rig: PhysicsUtil.HoldRig,
	collisionSnapshot: PhysicsUtil.CollisionSnapshot,
}

local PickupService = {}

-- Active holds keyed by player. At most one object per player.
local held: { [Player]: HeldData } = {}
local remotes: Remotes.RemoteSet

------------------------------------------------------------------
-- Collision groups
------------------------------------------------------------------

local function ensureCollisionGroups()
	-- RegisterCollisionGroup throws if the group already exists, so guard it.
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CharacterCollisionGroup)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.HeldCollisionGroup)

	-- Held objects pass through characters (no self-flinging, no shoving players)
	PhysicsService:CollisionGroupSetCollidable(
		Config.HeldCollisionGroup,
		Config.CharacterCollisionGroup,
		false
	)
	-- ...but held objects still collide with the world (Default group / walls)
	-- and with each other, which are both on by default.
	PhysicsService:CollisionGroupSetCollidable(
		Config.HeldCollisionGroup,
		Config.HeldCollisionGroup,
		true
	)
end

local function assignCharacterGroup(character: Model)
	for _, part in PhysicsUtil.getParts(character) do
		part.CollisionGroup = Config.CharacterCollisionGroup
	end
	-- Accessories / parts streamed in later (e.g. hats) also get grouped.
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Config.CharacterCollisionGroup
		end
	end)
end

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

local function getReferencePart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	-- Prefer the head (eye level) and fall back to the root.
	return (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

------------------------------------------------------------------
-- Drop
------------------------------------------------------------------

function PickupService.drop(player: Player)
	local data = held[player]
	if not data then
		return
	end
	held[player] = nil

	PhysicsUtil.destroyHoldRig(data.rig)
	PhysicsUtil.restoreCollisionGroup(data.collisionSnapshot)

	if data.interactable and data.interactable.Parent then
		data.interactable:SetAttribute(HELD_ATTRIBUTE, nil)
	end

	-- Return physics ownership to the engine's automatic heuristic.
	if data.primary and data.primary.Parent then
		pcall(function()
			data.primary:SetNetworkOwnershipAuto()
		end)
	end

	remotes.DropGranted:FireClient(player, data.interactable)
end

------------------------------------------------------------------
-- Pickup
------------------------------------------------------------------

local function onPickupRequest(player: Player, target: Instance?)
	-- Already holding something? Ignore (client should have sent a drop).
	if held[player] then
		return
	end

	-- Basic argument sanity.
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
		return
	end

	if not isAlive(player) then
		return
	end

	-- Re-derive the interactable on the server; never trust the client's pick.
	local interactable = Interactable.resolve(target)
	if not interactable then
		return
	end

	-- Already held by someone (this player or another)?
	if interactable:GetAttribute(HELD_ATTRIBUTE) ~= nil then
		return
	end

	local primary = PhysicsUtil.getPrimaryPart(interactable)
	if not primary then
		return
	end

	-- Anchored objects cannot be network-owned or dragged.
	if primary.Anchored then
		return
	end

	-- Distance validation against the server's own positions (anti-exploit).
	local reference = getReferencePart(player)
	if not reference then
		return
	end
	local distance = (primary.Position - reference.Position).Magnitude
	if distance > Config.MaxPickupDistance + Config.ServerDistanceTolerance then
		return
	end

	-- Mass sanity check.
	if primary.AssemblyMass > Config.MaxObjectMass then
		return
	end

	-- Make sure ownership can actually be transferred before mutating anything.
	local canOwn = primary:CanSetNetworkOwnership()
	if not canOwn then
		return
	end

	-- Commit: hand ownership to the client for zero-lag physics.
	local ok = pcall(function()
		primary:SetNetworkOwner(player)
	end)
	if not ok then
		return
	end

	local rig = PhysicsUtil.createHoldRig(primary)
	local collisionSnapshot = PhysicsUtil.applyCollisionGroup(interactable, Config.HeldCollisionGroup)
	interactable:SetAttribute(HELD_ATTRIBUTE, player.UserId)

	held[player] = {
		interactable = interactable,
		primary = primary,
		rig = rig,
		collisionSnapshot = collisionSnapshot,
	}

	remotes.PickupGranted:FireClient(player, interactable, primary)
end

------------------------------------------------------------------
-- Leash loop (anti-cheat + cleanup of vanished objects)
------------------------------------------------------------------

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < Config.LeashCheckInterval then
			return
		end
		accumulator = 0

		for player, data in held do
			-- Object destroyed / parented out of Workspace, or player died.
			if
				not data.primary
				or not data.primary.Parent
				or not data.primary:IsDescendantOf(workspace)
				or not isAlive(player)
			then
				PickupService.drop(player)
			else
				local reference = getReferencePart(player)
				if not reference then
					PickupService.drop(player)
				else
					local distance = (data.primary.Position - reference.Position).Magnitude
					if distance > Config.MaxHoldDistance then
						PickupService.drop(player)
					end
				end
			end
		end
	end)
end

------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if player.Character then
		assignCharacterGroup(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		-- Dropping on respawn happens via the leash loop's isAlive check, but
		-- clear immediately too so the old rig never lingers.
		PickupService.drop(player)
		assignCharacterGroup(character)
	end)
end

local function onPlayerRemoving(player: Player)
	PickupService.drop(player)
end

function PickupService.start()
	remotes = Remotes.get()

	ensureCollisionGroups()

	remotes.PickupRequest.OnServerEvent:Connect(onPickupRequest)
	remotes.DropRequest.OnServerEvent:Connect(function(player)
		PickupService.drop(player)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	startLeashLoop()
end

return PickupService
