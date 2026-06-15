--!strict
-- Module: Authoritative single-slot hold state for Weapon | Prop | None.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))
type HoldState = SharedTypes.HoldState
type RemotesModule = typeof(require(script.Parent.Remotes))
type RemoteBundle = RemotesModule.RemoteBundle

local PlayerHoldState = {}

local remotes: RemoteBundle? = nil
local states: { [Player]: HoldState } = {}

local function defaultState(): HoldState
	return {
		kind = "None",
		instance = nil,
		weaponId = nil,
	}
end

local function getState(player: Player): HoldState
	local current = states[player]
	if current then
		return current
	end
	local created = defaultState()
	states[player] = created
	return created
end

local function fireChanged(player: Player, state: HoldState)
	if remotes then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance)
	end
end

function PlayerHoldState.start(remoteBundle: RemoteBundle)
	remotes = remoteBundle
end

function PlayerHoldState.get(player: Player): HoldState
	local state = getState(player)
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = {
		kind = "Weapon",
		instance = weapon,
		weaponId = weaponId,
	}
	fireChanged(player, states[player])
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = {
		kind = "Prop",
		instance = prop,
		weaponId = nil,
	}
	fireChanged(player, states[player])
	return previous
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = PlayerHoldState.get(player)
	states[player] = defaultState()
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
