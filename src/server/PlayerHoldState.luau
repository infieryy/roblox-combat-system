--!strict
-- Module: server/PlayerHoldState.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Config = require(ReplicatedStorage.Shared.Config)

type HoldState = Types.HoldState

local PlayerHoldState = {}

local states: { [Player]: HoldState } = {}
local remotes: { HoldStateChanged: RemoteEvent }? = nil

local EMPTY: HoldState = { kind = "None", instance = nil, weaponId = nil }

local function copyState(state: HoldState): HoldState
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

local function broadcast(player: Player, state: HoldState)
	if remotes then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance, state.weaponId)
	end
end

function PlayerHoldState.configure(remoteTable: { HoldStateChanged: RemoteEvent })
	remotes = remoteTable
end

function PlayerHoldState.get(player: Player): HoldState
	return copyState(states[player] or EMPTY)
end

function PlayerHoldState.isHolding(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.kind ~= "None"
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = copyState(states[player] or EMPTY)
	states[player] = copyState(EMPTY)
	broadcast(player, states[player])
	return previous
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = copyState(states[player] or EMPTY)
	states[player] = {
		kind = "Weapon",
		instance = weapon,
		weaponId = weaponId,
	}
	broadcast(player, states[player])
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = copyState(states[player] or EMPTY)
	states[player] = {
		kind = "Prop",
		instance = prop,
		weaponId = nil,
	}
	broadcast(player, states[player])
	return previous
end

function PlayerHoldState.onPlayerRemoving(player: Player)
	states[player] = nil
end

return PlayerHoldState
