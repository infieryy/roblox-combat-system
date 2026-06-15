--!strict
-- Module: server/PhysicsAuthority.luau
-- Ported from consensus PickupServer collision + ownership helpers.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local GeometryUtil = require(ReplicatedStorage.Shared.GeometryUtil)

local PhysicsAuthority = {}

function PhysicsAuthority.registerCollisionGroups()
	local held = Config.CollisionGroups.heldObjects
	local characters = Config.CollisionGroups.characters
	local defaultGroup = Config.CollisionGroups.default

	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, held)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, characters)

	PhysicsService:CollisionGroupSetCollidable(held, characters, false)
	PhysicsService:CollisionGroupSetCollidable(held, held, true)
	PhysicsService:CollisionGroupSetCollidable(held, defaultGroup, true)
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
