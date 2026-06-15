--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local AmmoLedger = {}

local ammoByPlayer: { [Player]: { [string]: number } } = {}

local function ensureState(player: Player): { [string]: number }
	local existing = ammoByPlayer[player]
	if existing then
		return existing
	end
	local created: { [string]: number } = {}
	ammoByPlayer[player] = created
	return created
end

local function getMagazineSize(weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	return def.magazineSize
end

function AmmoLedger.start() end

function AmmoLedger.onEquip(player: Player, weaponId: string): number
	local state = ensureState(player)
	if state[weaponId] == nil then
		state[weaponId] = getMagazineSize(weaponId)
	end
	return state[weaponId]
end

function AmmoLedger.getAmmo(player: Player, weaponId: string): number
	local state = ensureState(player)
	if state[weaponId] == nil then
		state[weaponId] = getMagazineSize(weaponId)
	end
	return state[weaponId]
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): (boolean, number)
	local ammo = AmmoLedger.getAmmo(player, weaponId)
	if ammo <= 0 then
		return false, ammo
	end
	local nextAmmo = ammo - 1
	ensureState(player)[weaponId] = nextAmmo
	return true, nextAmmo
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local nextAmmo = getMagazineSize(weaponId)
	ensureState(player)[weaponId] = nextAmmo
	return nextAmmo
end

function AmmoLedger.cleanup(player: Player)
	ammoByPlayer[player] = nil
end

return AmmoLedger
