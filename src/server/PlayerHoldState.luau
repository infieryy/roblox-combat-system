--!strict
-- Module: PlayerHoldState
-- Single source of truth for what each player is currently holding.
-- Enforces the one-item rule: a player can hold a Weapon OR a Prop, never both.
--
-- Only this module mutates hold state. DragService and EquipService read and
-- set through this API; they never maintain their own "am I holding X" flags.
--
-- Cross-service teardown contract:
--   setWeapon / setProp return the PREVIOUS HoldState.
--   The caller is responsible for running the appropriate teardown:
--     previous.kind == "Prop"   → DragService.forceRelease(player)
--     previous.kind == "Weapon" → EquipService.forceUnequip(player)
--
-- init() must be called once from init.server.luau before any service connects remotes.

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Types"))

local PlayerHoldState = {}

local holdStates: { [Player]: Types.HoldState } = {}
local HoldStateChangedRemote: RemoteEvent

local NONE_STATE: Types.HoldState = { kind = "None", instance = nil, weaponId = nil }

-- -------------------------------------------------------------------------
-- Init (called once from init.server.luau)
-- -------------------------------------------------------------------------

function PlayerHoldState.init(holdStateChangedRemote: RemoteEvent)
	HoldStateChangedRemote = holdStateChangedRemote
end

-- -------------------------------------------------------------------------
-- Read
-- -------------------------------------------------------------------------

function PlayerHoldState.get(player: Player): Types.HoldState
	return holdStates[player] or { kind = "None", instance = nil, weaponId = nil }
end

function PlayerHoldState.isHolding(player: Player): boolean
	return PlayerHoldState.get(player).kind ~= "None"
end

-- -------------------------------------------------------------------------
-- Write  (each returns the PREVIOUS state for caller-side teardown)
-- -------------------------------------------------------------------------

function PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string): Types.HoldState
	local previous = PlayerHoldState.get(player)
	holdStates[player] = { kind = "Weapon", instance = weapon, weaponId = weaponId }
	if HoldStateChangedRemote then
		HoldStateChangedRemote:FireClient(player, "Weapon", weapon)
	end
	return previous
end

function PlayerHoldState.setProp(player: Player, prop: Instance): Types.HoldState
	local previous = PlayerHoldState.get(player)
	holdStates[player] = { kind = "Prop", instance = prop, weaponId = nil }
	if HoldStateChangedRemote then
		HoldStateChangedRemote:FireClient(player, "Prop", prop)
	end
	return previous
end

function PlayerHoldState.clear(player: Player): Types.HoldState
	local previous = PlayerHoldState.get(player)
	holdStates[player] = { kind = "None", instance = nil, weaponId = nil }
	if HoldStateChangedRemote then
		HoldStateChangedRemote:FireClient(player, "None", nil)
	end
	return previous
end

-- -------------------------------------------------------------------------
-- Cleanup
-- -------------------------------------------------------------------------

-- Called from init.server.luau on PlayerRemoving.
function PlayerHoldState.removePlayer(player: Player)
	holdStates[player] = nil
end

return PlayerHoldState
