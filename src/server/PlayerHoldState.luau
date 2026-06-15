--!strict
--[[
    PlayerHoldState  (server)
    -------------------------
    Single source of truth for what each player is currently holding.
    Rule: one item maximum — a weapon and a prop can never coexist.

    setWeapon / setProp each:
      1. Call clear() internally to wipe whatever was held before.
      2. Return the *previous* HoldState to the caller so it can run the
         appropriate cross-service teardown (DragService.forceRelease or
         EquipService.forceUnequip). This is the "cross-service teardown
         contract" from BLUEPRINT.md §16.

    Only this module is allowed to mutate the hold table.
    Every change fires HoldStateChanged to the affected player.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Types   = require(Shared:WaitForChild("Types") :: ModuleScript)

-- Remotes is required lazily to avoid a circular startup race (PlayerHoldState
-- is constructed before Remotes.get() is called in init.server).
local _remotes: { HoldStateChanged: RemoteEvent }? = nil
local function getRemotes()
    if not _remotes then
        local folder = ReplicatedStorage:WaitForChild("ItemSystemRemotes")
        _remotes = { HoldStateChanged = folder:WaitForChild("HoldStateChanged") :: RemoteEvent }
    end
    return _remotes :: { HoldStateChanged: RemoteEvent }
end

local NONE_STATE: Types.HoldState = { kind = "None", instance = nil, weaponId = nil }

-- Per-player hold state (only mutated by this module).
local holds: { [Player]: Types.HoldState } = {}

local PlayerHoldState = {}

local function fire(player: Player, state: Types.HoldState)
    if player.Parent then
        getRemotes().HoldStateChanged:FireClient(player, state.kind, state.instance)
    end
end

-- Returns the current hold state for a player (never nil; default is None).
function PlayerHoldState.get(player: Player): Types.HoldState
    return holds[player] or NONE_STATE
end

-- Sets the player's hold to a Weapon.
-- Returns the PREVIOUS hold state so the caller can run teardown on it.
function PlayerHoldState.setWeapon(
    player: Player,
    weapon: Instance,
    weaponId: string
): Types.HoldState
    local prev = PlayerHoldState.get(player)
    holds[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
    fire(player, holds[player] :: Types.HoldState)
    return prev
end

-- Sets the player's hold to a Prop.
-- Returns the PREVIOUS hold state so the caller can run teardown on it.
function PlayerHoldState.setProp(player: Player, prop: Instance): Types.HoldState
    local prev = PlayerHoldState.get(player)
    holds[player] = { kind = "Prop", instance = prop, weaponId = nil }
    fire(player, holds[player] :: Types.HoldState)
    return prev
end

-- Clears the player's hold to None.
-- Returns the PREVIOUS hold state (convenience for callers who need to teardown).
function PlayerHoldState.clear(player: Player): Types.HoldState
    local prev = PlayerHoldState.get(player)
    holds[player] = nil
    local none: Types.HoldState = { kind = "None", instance = nil, weaponId = nil }
    fire(player, none)
    return prev
end

-- Quick predicate.
function PlayerHoldState.isHolding(player: Player): boolean
    local h = holds[player]
    return h ~= nil and h.kind ~= "None"
end

-- Clean up when a player leaves.
Players.PlayerRemoving:Connect(function(player)
    holds[player] = nil
end)

return PlayerHoldState
