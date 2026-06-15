--!strict
-- Module: AmmoLedger
-- Server-authoritative ammo tracking (sole mutator).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local AmmoLedger = {}

type PlayerAmmo = { [string]: number }

local ammoByPlayer: { [Player]: PlayerAmmo } = {}

local function getPlayerAmmo(player: Player): PlayerAmmo
	local ammo = ammoByPlayer[player]
	if not ammo then
		ammo = {}
		ammoByPlayer[player] = ammo
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
	local ammo = ammoByPlayer[player]
	if not ammo then
		return 0
	end
	return ammo[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local ammo = getPlayerAmmo(player)
	local current = ammo[weaponId]
	if current == nil or current <= 0 then
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
	ammoByPlayer[player] = nil
end

return AmmoLedger
