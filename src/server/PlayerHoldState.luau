--!strict
-- Module: PlayerHoldState
-- Authoritative single-slot hold state per player (Weapon | Prop | None).

local Types = require(game.ReplicatedStorage.Shared.Types)

type HoldState = Types.HoldState
type RemotesTable = typeof(require(script.Parent.Remotes).build())

local PlayerHoldState = {}

local remotes: RemotesTable? = nil
local states: { [Player]: HoldState } = {}

local function emptyState(): HoldState
	return { kind = "None", instance = nil, weaponId = nil }
end

local function fireChanged(player: Player, state: HoldState)
	if remotes then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance, state.weaponId)
	end
end

function PlayerHoldState.init(remotesTable: RemotesTable)
	remotes = remotesTable
end

function PlayerHoldState.get(player: Player): HoldState
	local state = states[player]
	if not state then
		return emptyState()
	end
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
	fireChanged(player, states[player])
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = { kind = "Prop", instance = prop, weaponId = nil }
	fireChanged(player, states[player])
	return previous
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = emptyState()
	fireChanged(player, states[player])
	return previous
end

function PlayerHoldState.isHolding(player: Player): boolean
	return PlayerHoldState.get(player).kind ~= "None"
end

function PlayerHoldState.clearPlayer(player: Player)
	states[player] = nil
end

return PlayerHoldState
