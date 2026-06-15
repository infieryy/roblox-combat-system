--!strict
--[[
	PhysicsAuthority  (server/PhysicsAuthority.luau → ServerScriptService.Server.PhysicsAuthority)
	-------------------------------------------------------------------------------------------------
	Owns collision group registration and network ownership transfers.
	Ported verbatim from the consensus PickupServer — the same proven logic,
	just extracted into its own module so DragService and EquipService share it.

	Collision design:
	  • PickupHeldObjects × PickupCharacters  →  non-collidable
	      Held objects pass through characters so you can't shove yourself.
	  • PickupHeldObjects × PickupHeldObjects  →  collidable (two people can
	      hold props that bump into each other).
	  • PickupHeldObjects × Default           →  collidable (props still hit walls).
]]

local PhysicsService = game:GetService("PhysicsService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local Types        = require(Shared:WaitForChild("Types"))

local PhysicsAuthority = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Collision groups
-- ─────────────────────────────────────────────────────────────────────────────

function PhysicsAuthority.registerCollisionGroups()
	-- pcall: RegisterCollisionGroup throws if the group already exists
	-- (common on hot-reload in Studio).
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.heldObjects)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.characters)

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

-- Assign every part of a character to the characters collision group so held
-- objects pass through the holder.
function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in GeometryUtil.getParts(character) do
		part.CollisionGroup = Config.CollisionGroups.characters
	end
	-- Handle accessories added after spawn (hats, etc.).
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Config.CollisionGroups.characters
		end
	end)
end

-- Move every part of a target into the held-objects collision group.
-- Returns a snapshot of the previous groups for later restoration.
function PhysicsAuthority.applyHeldGroup(target: Instance): Types.CollisionSnapshot
	local snapshot: Types.CollisionSnapshot = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = Config.CollisionGroups.heldObjects
	end
	return snapshot
end

-- Restore collision groups saved by applyHeldGroup.
function PhysicsAuthority.restoreGroups(snapshot: Types.CollisionSnapshot?)
	if not snapshot then
		return
	end
	for part, group in snapshot do
		if part and part.Parent then
			part.CollisionGroup = group
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Network ownership
-- ─────────────────────────────────────────────────────────────────────────────

-- Transfer network ownership of a part's assembly to a specific player.
-- Returns false if the part cannot be given (e.g. an anchored assembly).
function PhysicsAuthority.giveOwnership(part: BasePart, player: Player): boolean
	local ok = pcall(function()
		if not part:CanSetNetworkOwnership() then
			error("cannot set ownership")
		end
		part:SetNetworkOwner(player)
	end)
	return ok
end

-- Return network ownership to automatic (server-determined).
function PhysicsAuthority.returnOwnership(part: BasePart)
	pcall(function()
		part:SetNetworkOwnershipAuto()
	end)
end

return PhysicsAuthority
