--!strict
-- Module: server/PhysicsAuthority
-- Collision-group isolation + network-ownership transfer, PORTED VERBATIM from
-- the consensus PickupServer (BLUEPRINT.md §6, §10.2). Held objects never
-- collide with characters (no self-flinging) but still collide with the world.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

local GROUPS = Config.CollisionGroups

-- Register the two runtime collision groups and make held-vs-character
-- non-collidable while held-vs-world and held-vs-held stay collidable.
function PhysicsAuthority.registerCollisionGroups()
	-- RegisterCollisionGroup throws if the group already exists (hot reload).
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, GROUPS.characters)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, GROUPS.heldObjects)

	PhysicsService:CollisionGroupSetCollidable(GROUPS.heldObjects, GROUPS.characters, false)
	PhysicsService:CollisionGroupSetCollidable(GROUPS.heldObjects, GROUPS.heldObjects, true)
	PhysicsService:CollisionGroupSetCollidable(GROUPS.heldObjects, GROUPS.default, true)
end

-- Put every part of a character into the character group (now and as new parts
-- are added).
function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = GROUPS.characters
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = GROUPS.characters
		end
	end)
end

-- Move every part of `target` into the held group, returning a snapshot of the
-- previous groups for restoration on drop.
function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = GROUPS.heldObjects
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

-- Transfer network ownership of the assembly to the holder (so they steer the
-- constraints locally with zero lag). Keeps the CanSetNetworkOwnership guard.
function PhysicsAuthority.giveOwnership(primaryPart: BasePart, player: Player?): boolean
	local ok = pcall(function()
		if not primaryPart:CanSetNetworkOwnership() then
			error("cannot set ownership")
		end
		primaryPart:SetNetworkOwner(player)
	end)
	return ok
end

function PhysicsAuthority.returnOwnership(primaryPart: BasePart)
	pcall(function()
		primaryPart:SetNetworkOwnershipAuto()
	end)
end

return PhysicsAuthority
