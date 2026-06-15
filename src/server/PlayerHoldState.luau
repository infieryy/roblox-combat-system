--!strict
--[[
	PlayerHoldState  (server/PlayerHoldState.luau → ServerScriptService.Server.PlayerHoldState)
	---------------------------------------------------------------------------------------------
	Single source of truth for what every player is currently holding.
	Only this module mutates hold state; all other modules read it.

	One-item rule:
	  setWeapon / setProp internally clear the previous hold FIRST, then
	  set the new one, then fire HoldStateChanged. They return the PREVIOUS
	  HoldState so the caller can run the right teardown:
	    • If prev.kind == "Prop"   → DragService.forceRelease(player)
	    • If prev.kind == "Weapon" → EquipService.forceUnequip(player)
	The caller is responsible for running teardown; PlayerHoldState only
	manages state and broadcasts — it never calls DragService/EquipService
	directly (that would create a circular dependency).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

local PlayerHoldState = {}

-- Per-player authoritative hold state.
local states: { [Player]: Types.HoldState } = {}

-- Lazy-loaded Remotes to avoid a circular require at module load time.
local function getRemotes()
	return require(script.Parent.Remotes).get()
end

local EMPTY_STATE: Types.HoldState = { kind = "None", instance = nil, weaponId = nil }

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function broadcast(player: Player, state: Types.HoldState)
	local ok, remotes = pcall(getRemotes)
	if ok then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance, state.weaponId)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the current hold state, or an empty state if the player has none.
function PlayerHoldState.get(player: Player): Types.HoldState
	return states[player] or { kind = "None", instance = nil, weaponId = nil }
end

-- Returns true when the player is holding anything.
function PlayerHoldState.isHolding(player: Player): boolean
	local s = states[player]
	return s ~= nil and s.kind ~= "None"
end

-- Set a new weapon hold.
-- Returns the PREVIOUS HoldState (caller must run EquipService/DragService teardown).
function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): Types.HoldState
	local prev = PlayerHoldState.get(player)
	states[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
	broadcast(player, states[player])
	return prev
end

-- Set a new prop hold.
-- Returns the PREVIOUS HoldState (caller must run EquipService/DragService teardown).
function PlayerHoldState.setProp(player: Player, prop: Instance): Types.HoldState
	local prev = PlayerHoldState.get(player)
	states[player] = { kind = "Prop", instance = prop, weaponId = nil }
	broadcast(player, states[player])
	return prev
end

-- Clear the hold state entirely (used by DragService.drop and EquipService.unequip).
-- Returns the PREVIOUS HoldState.
function PlayerHoldState.clear(player: Player): Types.HoldState
	local prev = PlayerHoldState.get(player)
	states[player] = nil :: any
	broadcast(player, EMPTY_STATE)
	return prev
end

-- Remove all state for a disconnected / removed player.
function PlayerHoldState.removePlayer(player: Player)
	states[player] = nil :: any
end

return PlayerHoldState
