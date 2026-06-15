--!strict
-- Module: PlayerHoldState
-- Authoritative single-slot hold state (weapon OR prop OR none).

local Types = require(game:GetService("ReplicatedStorage").Shared.Types)

type HoldState = Types.HoldState
type Remotes = typeof(require(script.Parent.Remotes).build())

local EMPTY_HOLD: HoldState = {
	kind = "None",
	instance = nil,
	weaponId = nil,
}

local PlayerHoldState = {}

local remotes: Remotes? = nil
local holds: { [Player]: HoldState } = {}

local function cloneHold(state: HoldState): HoldState
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

local function broadcast(player: Player, state: HoldState)
	if remotes and player.Parent then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance, state.weaponId)
	end
end

function PlayerHoldState.start(remoteTable: Remotes)
	remotes = remoteTable
end

function PlayerHoldState.get(player: Player): HoldState
	return cloneHold(holds[player] or EMPTY_HOLD)
end

function PlayerHoldState.isHolding(player: Player): boolean
	local state = holds[player]
	return state ~= nil and state.kind ~= "None"
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = cloneHold(holds[player] or EMPTY_HOLD)
	holds[player] = cloneHold(EMPTY_HOLD)
	broadcast(player, EMPTY_HOLD)
	return previous
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = cloneHold(holds[player] or EMPTY_HOLD)
	holds[player] = {
		kind = "Weapon",
		instance = weapon,
		weaponId = weaponId,
	}
	broadcast(player, holds[player])
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = cloneHold(holds[player] or EMPTY_HOLD)
	holds[player] = {
		kind = "Prop",
		instance = prop,
		weaponId = nil,
	}
	broadcast(player, holds[player])
	return previous
end

function PlayerHoldState.onPlayerRemoving(player: Player)
	holds[player] = nil
end

return PlayerHoldState
