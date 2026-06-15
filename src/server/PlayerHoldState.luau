--!strict
-- Module: server/PlayerHoldState
-- THE authoritative "what is each player holding" (one item max) — BLUEPRINT.md
-- §10.3. Replaces the consensus per-player single-object guard with a unified
-- Weapon | Prop | None slot. Only this module mutates hold state, and it is the
-- only module that fires HoldStateChanged.
--
-- Cross-service teardown contract (§16): setWeapon/setProp return the PREVIOUS
-- hold so the CALLER runs the right physical teardown (DragService.forceRelease
-- or EquipService.forceUnequip). This keeps the two services decoupled and
-- avoids a teardown re-entering and clobbering the freshly-set state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

type HoldState = Types.HoldState

local PlayerHoldState = {}

local NONE: HoldState = { kind = "None", instance = nil, weaponId = nil }

local states: { [Player]: HoldState } = {}
local remotes: any = nil

function PlayerHoldState.init(remotesTable: any)
	remotes = remotesTable
end

local function fireChanged(player: Player, state: HoldState)
	if remotes and player.Parent then
		remotes.HoldStateChanged:FireClient(player, state.kind, state.instance)
	end
end

function PlayerHoldState.get(player: Player): HoldState
	return states[player] or NONE
end

function PlayerHoldState.isHolding(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.kind ~= "None"
end

-- Set the player to holding a weapon, returning the PREVIOUS hold. The caller
-- inspects the return value and tears down the previous item if needed.
function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): HoldState
	local previous = states[player] or NONE
	states[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
	fireChanged(player, states[player])
	return previous
end

-- Set the player to holding a prop, returning the PREVIOUS hold.
function PlayerHoldState.setProp(player: Player, prop: Instance): HoldState
	local previous = states[player] or NONE
	states[player] = { kind = "Prop", instance = prop, weaponId = nil }
	fireChanged(player, states[player])
	return previous
end

-- Clear the player's hold, returning the PREVIOUS hold.
function PlayerHoldState.clear(player: Player): HoldState
	local previous = states[player] or NONE
	if previous.kind == "None" then
		return previous
	end
	states[player] = nil
	fireChanged(player, NONE)
	return previous
end

return PlayerHoldState
