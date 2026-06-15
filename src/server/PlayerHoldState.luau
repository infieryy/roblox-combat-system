--!strict
-- Module: PlayerHoldState
-- Authoritative single-slot hold state per player (weapon | prop | none).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

type HoldState = Types.HoldState

local PlayerHoldState = {}

local holdByPlayer: { [Player]: HoldState } = {}
local holdChangedCallback: ((player: Player, state: HoldState) -> ())? = nil

local EMPTY: HoldState = {
	kind = "None",
	instance = nil,
	weaponId = nil,
}

local function cloneState(state: HoldState): HoldState
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

function PlayerHoldState.setHoldChangedCallback(callback: (player: Player, state: HoldState) -> ())
	holdChangedCallback = callback
end

function PlayerHoldState.get(player: Player): HoldState
	return cloneState(holdByPlayer[player] or EMPTY)
end

function PlayerHoldState.isHolding(player: Player): boolean
	local state = holdByPlayer[player]
	return state ~= nil and state.kind ~= "None"
end

local function setState(player: Player, nextState: HoldState)
	holdByPlayer[player] = cloneState(nextState)
	if holdChangedCallback then
		holdChangedCallback(player, holdByPlayer[player])
	end
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = cloneState(holdByPlayer[player] or EMPTY)
	setState(player, {
		kind = "Weapon",
		instance = weapon,
		weaponId = weaponId,
	})
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = cloneState(holdByPlayer[player] or EMPTY)
	setState(player, {
		kind = "Prop",
		instance = prop,
		weaponId = nil,
	})
	return previous
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = cloneState(holdByPlayer[player] or EMPTY)
	setState(player, EMPTY)
	return previous
end

function PlayerHoldState.clearPlayer(player: Player)
	holdByPlayer[player] = nil
end

return PlayerHoldState
