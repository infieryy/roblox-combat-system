--!strict
-- Module: PhysicsAuthority
-- Collision groups and network ownership (ported from consensus PickupServer).

local PhysicsService = game:GetService("PhysicsService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local GeometryUtil = require(game:GetService("ReplicatedStorage").Shared.GeometryUtil)

local PhysicsAuthority = {}

function PhysicsAuthority.registerCollisionGroups()
	local held = Config.CollisionGroups.heldObjects
	local characters = Config.CollisionGroups.characters
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, held)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, characters)
	PhysicsService:CollisionGroupSetCollidable(held, characters, false)
	PhysicsService:CollisionGroupSetCollidable(held, held, true)
	PhysicsService:CollisionGroupSetCollidable(held, Config.CollisionGroups.default, true)
end

function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = Config.CollisionGroups.characters
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Config.CollisionGroups.characters
		end
	end)
end

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
