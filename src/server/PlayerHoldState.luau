--!strict
-- Module: server/PlayerHoldState
-- The authoritative "what is each player holding" slot — one item max
-- (Weapon | Prop | None). The ONLY module that mutates hold state. Enforces the
-- one-item rule (decision #3) and unifies the consensus single-object guard with
-- weapons.
--
-- Cross-service teardown contract (§16): setWeapon/setProp return the PREVIOUS
-- hold; the caller runs the right teardown (DragService.forceRelease /
-- EquipService.forceUnequip). This module never calls those services itself, so
-- there is no circular dependency.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

type HoldState = Types.HoldState
type Context = { [string]: any }

local PlayerHoldState = {}

local states: { [Player]: HoldState } = {}
local ctx: Context = nil :: any

local function none(): HoldState
	return { kind = "None", instance = nil, weaponId = nil }
end

local function fire(player: Player, state: HoldState)
	if ctx and ctx.remotes and player.Parent then
		ctx.remotes.HoldStateChanged:FireClient(player, state.kind, state.instance)
	end
end

function PlayerHoldState.start(context: Context)
	ctx = context
end

function PlayerHoldState.get(player: Player): HoldState
	return states[player] or none()
end

function PlayerHoldState.isHolding(player: Player): boolean
	return PlayerHoldState.get(player).kind ~= "None"
end

local function commit(player: Player, newState: HoldState): HoldState
	local previous = states[player] or none()
	states[player] = newState
	fire(player, newState)
	return previous
end

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	return commit(player, { kind = "Weapon", instance = weapon, weaponId = weaponId })
end

function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	return commit(player, { kind = "Prop", instance = prop, weaponId = nil })
end

function PlayerHoldState.clear(player: Player): HoldState
	local previous = states[player] or none()
	states[player] = none()
	if previous.kind ~= "None" then
		fire(player, states[player])
	end
	return previous
end

-- Drop all record of a player (on leaving).
function PlayerHoldState.remove(player: Player)
	states[player] = nil
end

return PlayerHoldState
