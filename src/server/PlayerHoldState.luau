--!strict
-- Module: PlayerHoldState
-- Authoritative "what is each player holding right now" table.
-- This is the ONLY module that mutates hold state. Enforces the one-item rule:
-- equipping a gun auto-drops a held prop, and grabbing a prop auto-unequips a gun.
--
-- Blueprint §10.3: setWeapon / setProp both return the PREVIOUS hold so callers
-- can run the correct teardown (DragService.forceRelease or EquipService.forceUnequip).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

type HoldState = Types.HoldState

-- Runtime remotes reference; injected by init.server via start().
local _HoldStateChanged: RemoteEvent? = nil

local EMPTY_STATE: HoldState = { kind = "None", instance = nil, weaponId = nil }

local states: { [Player]: HoldState } = {}

local PlayerHoldState = {}

-- -------------------------------------------------------------------------
-- Internal helpers
-- -------------------------------------------------------------------------

local function fireChanged(player: Player, state: HoldState)
	if _HoldStateChanged and player.Parent then
		_HoldStateChanged:FireClient(player, state.kind, state.instance)
	end
end

local function getState(player: Player): HoldState
	if not states[player] then
		states[player] = { kind = "None", instance = nil, weaponId = nil }
	end
	return states[player]
end

local function cloneState(state: HoldState): HoldState
	return { kind = state.kind, instance = state.instance, weaponId = state.weaponId }
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- Must be called at server startup with the HoldStateChanged remote.
function PlayerHoldState.start(holdStateChangedRemote: RemoteEvent)
	_HoldStateChanged = holdStateChangedRemote

	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

function PlayerHoldState.get(player: Player): HoldState
	return cloneState(getState(player))
end

function PlayerHoldState.isHolding(player: Player): boolean
	return getState(player).kind ~= "None"
end

-- Set weapon hold. Returns the PREVIOUS HoldState for caller teardown.
-- Caller is responsible for running EquipService.forceUnequip or DragService.forceRelease
-- on the returned state if needed.
function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local prev = cloneState(getState(player))
	states[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
	fireChanged(player, states[player])
	return prev
end

-- Set prop hold. Returns the PREVIOUS HoldState for caller teardown.
function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local prev = cloneState(getState(player))
	states[player] = { kind = "Prop", instance = prop, weaponId = nil }
	fireChanged(player, states[player])
	return prev
end

-- Clear all hold state. Returns the PREVIOUS HoldState for caller teardown.
function PlayerHoldState.clear(player: Player): HoldState
	local prev = cloneState(getState(player))
	states[player] = { kind = "None", instance = nil, weaponId = nil }
	fireChanged(player, states[player])
	return prev
end

return PlayerHoldState
