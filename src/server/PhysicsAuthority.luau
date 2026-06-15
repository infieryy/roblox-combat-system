--!strict
-- Module: PhysicsAuthority
-- Collision group management and network ownership helpers.
-- Ported verbatim from the consensus PickupServer build; moved to a shared
-- module so DragService and EquipService share one implementation.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

-- -------------------------------------------------------------------------
-- Collision groups
-- -------------------------------------------------------------------------

-- Called once at server startup. Safe to call again on hot-reload (pcall).
function PhysicsAuthority.registerCollisionGroups()
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.heldObjects)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.characters)

	-- Held objects pass through characters but still hit the world and each other.
	PhysicsService:CollisionGroupSetCollidable(
		Config.CollisionGroups.heldObjects,
		Config.CollisionGroups.characters,
		false
	)
	PhysicsService:CollisionGroupSetCollidable(
		Config.CollisionGroups.heldObjects,
		Config.CollisionGroups.heldObjects,
		true
	)
	PhysicsService:CollisionGroupSetCollidable(
		Config.CollisionGroups.heldObjects,
		Config.CollisionGroups.default,
		true
	)
end

-- Assign every part of a spawning character to the character collision group so
-- held objects can pass through them.
function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = Config.CollisionGroups.characters
	end
	-- Catch accessories and tools added after spawn.
	character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			(descendant :: BasePart).CollisionGroup = Config.CollisionGroups.characters
		end
	end)
end

-- Move every part of `target` into the held-objects group, returning a snapshot
-- of the previous groups so they can be restored on drop.
function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = Config.CollisionGroups.heldObjects
	end
	return snapshot
end

function PhysicsAuthority.restoreGroups(snapshot: { [BasePart]: string })
	for part, group in snapshot do
		if part and part.Parent then
			part.CollisionGroup = group
		end
	end
end

-- -------------------------------------------------------------------------
-- Network ownership
-- -------------------------------------------------------------------------

-- Grant `player` ownership of `primaryPart` (and thus its whole assembly).
-- Returns true on success. Fails silently when ownership cannot be transferred
-- (e.g. a Workspace-anchored assembly or a Studio-owned part).
function PhysicsAuthority.giveOwnership(primaryPart: BasePart, player: Player): boolean
	local ok = pcall(function()
		if not primaryPart:CanSetNetworkOwnership() then
			error("cannot set")
		end
		primaryPart:SetNetworkOwner(player)
	end)
	return ok
end

-- Return ownership to the automatic (server-determined) assignment.
function PhysicsAuthority.returnOwnership(primaryPart: BasePart)
	pcall(function()
		primaryPart:SetNetworkOwnershipAuto()
	end)
end

return PhysicsAuthority
