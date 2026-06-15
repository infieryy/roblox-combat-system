--!strict
-- Module: Server-authoritative ammo storage and mutation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local AmmoLedger = {}

local ammoByPlayer: { [Player]: { [string]: number } } = {}

local function getPlayerLedger(player: Player): { [string]: number }
	local existing = ammoByPlayer[player]
	if existing then
		return existing
	end
	local created: { [string]: number } = {}
	ammoByPlayer[player] = created
	return created
end

function AmmoLedger.start() end

function AmmoLedger.onEquip(player: Player, weaponId: string)
	local ledger = getPlayerLedger(player)
	if ledger[weaponId] ~= nil then
		return
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end
	ledger[weaponId] = def.maxAmmo
end

function AmmoLedger.get(player: Player, weaponId: string): number
	local ledger = getPlayerLedger(player)
	local current = ledger[weaponId]
	if current == nil then
		local def = ItemRegistry.getWeaponDef(weaponId)
		if not def then
			return 0
		end
		ledger[weaponId] = def.maxAmmo
		return def.maxAmmo
	end
	return current
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local current = AmmoLedger.get(player, weaponId)
	if current <= 0 then
		return false
	end
	getPlayerLedger(player)[weaponId] = current - 1
	return true
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	getPlayerLedger(player)[weaponId] = def.maxAmmo
	return def.maxAmmo
end

function AmmoLedger.clearPlayer(player: Player)
	ammoByPlayer[player] = nil
end

return AmmoLedger
