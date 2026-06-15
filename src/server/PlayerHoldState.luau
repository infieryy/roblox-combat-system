--!strict

local _Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Types"))

type HoldState = _Types.HoldState

local PlayerHoldState = {}

local remotes: any = nil
local holds: { [Player]: HoldState } = {}

local function cloneState(state: HoldState): HoldState
	return {
		kind = state.kind,
		instance = state.instance,
		weaponId = state.weaponId,
	}
end

local function getDefaultState(): HoldState
	return {
		kind = "None",
		instance = nil,
		weaponId = nil,
	}
end

local function pushState(player: Player, state: HoldState)
	if not remotes then
		return
	end
	remotes.HoldStateChanged:FireClient(player, cloneState(state))
end

local function setState(player: Player, state: HoldState): HoldState
	local previous = PlayerHoldState.get(player)
	holds[player] = state
	pushState(player, state)
	return previous
end

function PlayerHoldState.start(remoteMap: any)
	remotes = remoteMap
end

function PlayerHoldState.get(player: Player): HoldState
	local existing = holds[player]
	if existing then
		return cloneState(existing)
	end
	return getDefaultState()
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local nextState: HoldState = {
		kind = "Weapon",
		instance = weapon,
		weaponId = weaponId,
	}
	return setState(player, nextState)
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local nextState: HoldState = {
		kind = "Prop",
		instance = prop,
		weaponId = nil,
	}
	return setState(player, nextState)
end

function PlayerHoldState.clear(player: Player): HoldState
	return setState(player, getDefaultState())
end

function PlayerHoldState.cleanup(player: Player)
	holds[player] = nil
end

return PlayerHoldState
