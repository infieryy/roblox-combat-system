--!strict
-- Module: server/PhysicsAuthority
-- Ported from the consensus PickupServer: collision-group isolation (held
-- objects never collide with characters) and network-ownership transfer.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

local HELD = Config.CollisionGroups.heldObjects
local CHARACTERS = Config.CollisionGroups.characters
local DEFAULT = Config.CollisionGroups.default

function PhysicsAuthority.registerCollisionGroups()
	-- RegisterCollisionGroup throws if the group already exists (hot reload).
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, CHARACTERS)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, HELD)

	-- Held objects pass through characters, still collide with the world and
	-- each other.
	PhysicsService:CollisionGroupSetCollidable(HELD, CHARACTERS, false)
	PhysicsService:CollisionGroupSetCollidable(HELD, HELD, true)
	PhysicsService:CollisionGroupSetCollidable(HELD, DEFAULT, true)
end

function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = CHARACTERS
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = CHARACTERS
		end
	end)
end

-- Move every part of `target` into the held group; returns a snapshot so the
-- previous groups can be restored on release.
function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = HELD
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
