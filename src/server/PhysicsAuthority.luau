--!strict
-- Module: PhysicsAuthority
-- Collision-group management and network-ownership helpers.
-- Ported verbatim from the consensus PickupServer (ensureCollisionGroups,
-- assignCharacterGroup, applyCollisionGroup, restoreCollisionGroups,
-- giveOwnership, resetOwnership) and re-housed here as the single authority
-- on Roblox physics bookkeeping.

local PhysicsService = game:GetService("PhysicsService")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local PhysicsAuthority = {}

-- -------------------------------------------------------------------------
-- Collision groups
-- -------------------------------------------------------------------------

-- Registers the two custom groups and sets the one non-collidable pairing.
-- Called once from init.server.luau before any service starts.
-- pcall guards against re-registration on hot-reload.
function PhysicsAuthority.registerCollisionGroups()
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.heldObjects)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CollisionGroups.characters)

	-- Held objects pass through players (no shoving) but still collide with the world.
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

-- Assign every part of a character (and any future parts added via DescendantAdded)
-- to the PickupCharacters group so held objects pass through them.
function PhysicsAuthority.assignCharacterToGroup(character: Model)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = Config.CollisionGroups.characters
		end
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Config.CollisionGroups.characters
		end
	end)
end

-- Move every part of `target` into the held-objects group.
-- Returns a snapshot of the previous groups so they can be restored on drop.
function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	for _, part in target:GetDescendants() do
		if part:IsA("BasePart") then
			snapshot[part] = part.CollisionGroup
			part.CollisionGroup = Config.CollisionGroups.heldObjects
		end
	end
	if target:IsA("BasePart") then
		snapshot[target :: BasePart] = (target :: BasePart).CollisionGroup
		;(target :: BasePart).CollisionGroup = Config.CollisionGroups.heldObjects
	end
	return snapshot
end

-- Restore all parts to their previous collision groups.
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

-- Transfer network ownership of primaryPart to the given player.
-- Returns true on success, false if ownership cannot be set (e.g., anchored anchor parts).
function PhysicsAuthority.giveOwnership(primaryPart: BasePart, player: Player?): boolean
	local ok = pcall(function()
		if not primaryPart:CanSetNetworkOwnership() then
			error("cannot set network ownership")
		end
		primaryPart:SetNetworkOwner(player)
	end)
	return ok
end

-- Return network ownership to automatic (server-managed) mode.
function PhysicsAuthority.returnOwnership(primaryPart: BasePart)
	pcall(function()
		primaryPart:SetNetworkOwnershipAuto()
	end)
end

return PhysicsAuthority
