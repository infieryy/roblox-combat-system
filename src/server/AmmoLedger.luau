--!strict
--[[
	AmmoLedger  (server/AmmoLedger.luau → ServerScriptService.Server.AmmoLedger)
	------------------------------------------------------------------------------
	Authoritative, server-only ammo store. This is the ONLY module that reads
	or writes ammo counts. No other module may bypass it.

	Per-player, per-weapon tracking means a player switching between weapons
	remembers each weapon's remaining ammo independently.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local AmmoLedger = {}

-- ammoData[player][weaponId] = current rounds
local ammoData: { [Player]: { [string]: number } } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Call when a player equips a weapon. Initialises ammo to max if this is the
-- first time this player has held this weapon; preserves existing ammo otherwise.
function AmmoLedger.onEquip(player: Player, weaponId: string)
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		warn(string.format("[AmmoLedger] Unknown weaponId '%s' on equip.", weaponId))
		return
	end
	if not ammoData[player] then
		ammoData[player] = {}
	end
	-- Only initialise if we have never seen this weapon for this player.
	if ammoData[player][weaponId] == nil then
		ammoData[player][weaponId] = def.maxAmmo
	end
end

-- Returns the current ammo count, or 0 if unknown.
function AmmoLedger.get(player: Player, weaponId: string): number
	local byPlayer = ammoData[player]
	if not byPlayer then
		return 0
	end
	return byPlayer[weaponId] or 0
end

-- Returns true when the player can fire (ammo > 0).
function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

-- Deducts one round. Returns true on success, false if out of ammo.
function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	if not AmmoLedger.canFire(player, weaponId) then
		return false
	end
	ammoData[player][weaponId] -= 1
	return true
end

-- Refills ammo to max. Returns the new ammo count.
function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	if not ammoData[player] then
		ammoData[player] = {}
	end
	ammoData[player][weaponId] = def.maxAmmo
	return def.maxAmmo
end

-- Clean up when a player leaves.
function AmmoLedger.clearPlayer(player: Player)
	ammoData[player] = nil :: any
end

return AmmoLedger
