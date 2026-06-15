--!strict
-- Module: server/AmmoLedger.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)

local AmmoLedger = {}

type PlayerAmmo = { [string]: number }

local ledger: { [Player]: PlayerAmmo } = {}

function AmmoLedger.onEquip(player: Player, weaponId: string)
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end
	local playerAmmo = ledger[player]
	if not playerAmmo then
		playerAmmo = {}
		ledger[player] = playerAmmo
	end
	if playerAmmo[weaponId] == nil then
		playerAmmo[weaponId] = def.maxAmmo
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	local playerAmmo = ledger[player]
	if not playerAmmo then
		return 0
	end
	return playerAmmo[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local playerAmmo = ledger[player]
	if not playerAmmo then
		return false
	end
	local current = playerAmmo[weaponId]
	if not current or current <= 0 then
		return false
	end
	playerAmmo[weaponId] = current - 1
	return true
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	local playerAmmo = ledger[player]
	if not playerAmmo then
		playerAmmo = {}
		ledger[player] = playerAmmo
	end
	playerAmmo[weaponId] = def.maxAmmo
	return def.maxAmmo
end

function AmmoLedger.clearPlayer(player: Player)
	ledger[player] = nil
end

return AmmoLedger
