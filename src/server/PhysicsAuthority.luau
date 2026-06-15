--!strict
--[[
    PhysicsAuthority  (server)
    --------------------------
    Collision groups and network ownership helpers.
    Ported verbatim from the consensus PickupServer.

    Rule enforced by registerCollisionGroups():
      heldObjects × characters  = non-collidable  (held props never shove the holder)
      heldObjects × heldObjects = collidable       (props can hit each other)
      heldObjects × Default     = collidable       (props still hit the world)
]]

local PhysicsService    = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil") :: ModuleScript)

local CG = Config.CollisionGroups

local PhysicsAuthority = {}

-- Creates (idempotent — pcall-safe on hot-reload) the two collision groups and
-- sets the non-collidable rule between them.
function PhysicsAuthority.registerCollisionGroups()
    pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, CG.heldObjects)
    pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, CG.characters)

    PhysicsService:CollisionGroupSetCollidable(CG.heldObjects, CG.characters,  false)
    PhysicsService:CollisionGroupSetCollidable(CG.heldObjects, CG.heldObjects, true)
    PhysicsService:CollisionGroupSetCollidable(CG.heldObjects, CG.default,     true)
end

-- Assigns every BasePart in a freshly spawned character to the characters group.
-- Also hooks DescendantAdded so accessories added later are covered automatically.
function PhysicsAuthority.assignCharacterToGroup(character: Model)
    for _, part in GeometryUtil.getParts(character) do
        part.CollisionGroup = CG.characters
    end
    character.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            (descendant :: BasePart).CollisionGroup = CG.characters
        end
    end)
end

-- Moves every BasePart of target into the heldObjects group, returning a
-- snapshot of prior groups so they can be restored exactly on drop.
function PhysicsAuthority.applyHeldGroup(target: Instance): { [BasePart]: string }
    local snapshot: { [BasePart]: string } = {}
    for _, part in GeometryUtil.getParts(target) do
        snapshot[part] = part.CollisionGroup
        part.CollisionGroup = CG.heldObjects
    end
    return snapshot
end

-- Restores collision groups from the snapshot returned by applyHeldGroup.
function PhysicsAuthority.restoreGroups(snapshot: { [BasePart]: string })
    for part, group in snapshot do
        if part and part.Parent then
            part.CollisionGroup = group
        end
    end
end

-- Transfers network ownership of a BasePart to a player so the client can
-- steer constraint goals locally with zero perceived lag.
-- Returns false if the part is ineligible (anchored, part of the terrain, etc.).
function PhysicsAuthority.giveOwnership(primaryPart: BasePart, player: Player): boolean
    local ok, err = pcall(function()
        if not primaryPart:CanSetNetworkOwnership() then
            error("part is not eligible for network ownership transfer")
        end
        primaryPart:SetNetworkOwner(player)
    end)
    if not ok then
        warn("[PhysicsAuthority] giveOwnership failed:", err)
    end
    return ok
end

-- Returns network ownership to automatic (server-decides) mode.
function PhysicsAuthority.returnOwnership(primaryPart: BasePart)
    pcall(primaryPart.SetNetworkOwnershipAuto, primaryPart)
end

return PhysicsAuthority
