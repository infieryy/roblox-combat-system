--!strict
-- Module: AmmoLedger
-- Sole authoritative ammo mutator.

local ItemRegistry = require(game:GetService("ReplicatedStorage").Shared.ItemRegistry)

local AmmoLedger = {}

type PlayerAmmo = { [string]: number }

local ammoByPlayer: { [Player]: PlayerAmmo } = {}

local function getPlayerAmmo(player: Player): PlayerAmmo
	local bucket = ammoByPlayer[player]
	if not bucket then
		bucket = {}
		ammoByPlayer[player] = bucket
	end
	return bucket
end

function AmmoLedger.onEquip(player: Player, weaponId: string)
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end
	local bucket = getPlayerAmmo(player)
	if bucket[weaponId] == nil then
		bucket[weaponId] = def.maxAmmo
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	return getPlayerAmmo(player)[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local bucket = getPlayerAmmo(player)
	local current = bucket[weaponId]
	if current == nil or current <= 0 then
		return false
	end
	bucket[weaponId] = current - 1
	return true
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	local bucket = getPlayerAmmo(player)
	bucket[weaponId] = def.maxAmmo
	return def.maxAmmo
end

function AmmoLedger.clearPlayer(player: Player)
	ammoByPlayer[player] = nil
end

return AmmoLedger
