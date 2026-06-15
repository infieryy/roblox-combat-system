--!strict
-- Module: Collision group and network ownership authority.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

function PhysicsAuthority.registerCollisionGroups()
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.characters)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.heldObjects)

	PhysicsService:CollisionGroupSetCollidable(Config.CollisionGroups.heldObjects, Config.CollisionGroups.characters, false)
	PhysicsService:CollisionGroupSetCollidable(Config.CollisionGroups.heldObjects, Config.CollisionGroups.heldObjects, true)
	PhysicsService:CollisionGroupSetCollidable(Config.CollisionGroups.heldObjects, Config.CollisionGroups.default, true)
end

function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = Config.CollisionGroups.characters
	end

	character.DescendantAdded:Connect(function(descendant: Instance)
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

function PhysicsAuthority.giveOwnership(primaryPart: BasePart, player: Player): boolean
	local ok = pcall(function()
		if not primaryPart:CanSetNetworkOwnership() then
			error("cannot set network ownership")
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
