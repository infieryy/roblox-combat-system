--!strict
-- Module: PhysicsAuthority
-- Collision groups and network ownership (ported from consensus PickupServer).

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

function PhysicsAuthority.registerCollisionGroups()
	local held = Config.CollisionGroups.heldObjects
	local characters = Config.CollisionGroups.characters

	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, characters)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, held)

	PhysicsService:CollisionGroupSetCollidable(held, characters, false)
	PhysicsService:CollisionGroupSetCollidable(held, held, true)
	PhysicsService:CollisionGroupSetCollidable(held, Config.CollisionGroups.default, true)
end

function PhysicsAuthority.assignCharacterToGroup(character: Model)
	local group = Config.CollisionGroups.characters
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = group
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end)
end

function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	local group = Config.CollisionGroups.heldObjects
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = group
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

function PhysicsAuthority.giveOwnership(part: BasePart, player: Player?): boolean
	local ok = pcall(function()
		if not part:CanSetNetworkOwnership() then
			error("cannot set ownership")
		end
		part:SetNetworkOwner(player)
	end)
	return ok
end

function PhysicsAuthority.returnOwnership(part: BasePart)
	pcall(function()
		part:SetNetworkOwnershipAuto()
	end)
end

return PhysicsAuthority
