--!strict
-- Module: AmmoLedger
-- Server-authoritative ammo tracking (sole mutator).

local ItemRegistry = require(game.ReplicatedStorage.Shared.ItemRegistry)

local AmmoLedger = {}

type PlayerAmmo = { [string]: number }

local ledger: { [Player]: PlayerAmmo } = {}

local function getPlayerAmmo(player: Player): PlayerAmmo
	local ammo = ledger[player]
	if not ammo then
		ammo = {}
		ledger[player] = ammo
	end
	return ammo
end

function AmmoLedger.onEquip(player: Player, weaponId: string)
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end
	local ammo = getPlayerAmmo(player)
	if ammo[weaponId] == nil then
		ammo[weaponId] = def.maxAmmo
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	return getPlayerAmmo(player)[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local ammo = getPlayerAmmo(player)
	local current = ammo[weaponId] or 0
	if current <= 0 then
		return false
	end
	ammo[weaponId] = current - 1
	return true
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	local ammo = getPlayerAmmo(player)
	ammo[weaponId] = def.maxAmmo
	return ammo[weaponId]
end

function AmmoLedger.clearPlayer(player: Player)
	ledger[player] = nil
end

return AmmoLedger
