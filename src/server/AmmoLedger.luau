--!strict
-- Module: server/AmmoLedger
-- The authoritative, SOLE ammo mutator (anti-cheat core). No other module is
-- allowed to change ammo. Tracked per player + per weaponId so a player keeps a
-- separate magazine for each gun.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

local AmmoLedger = {}

local ammo: { [Player]: { [string]: number } } = {}

function AmmoLedger.start(_context: Context)
	-- No dependencies needed; ItemRegistry is required directly.
end

-- Initialise a weapon to a full magazine the first time it is equipped.
function AmmoLedger.onEquip(player: Player, weaponId: string)
	local perPlayer = ammo[player]
	if not perPlayer then
		perPlayer = {}
		ammo[player] = perPlayer
	end
	if perPlayer[weaponId] == nil then
		local def = ItemRegistry.getWeaponDef(weaponId)
		perPlayer[weaponId] = def and def.maxAmmo or 0
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	local perPlayer = ammo[player]
	if not perPlayer then
		return 0
	end
	return perPlayer[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	if not AmmoLedger.canFire(player, weaponId) then
		return false
	end
	ammo[player][weaponId] -= 1
	return true
end

function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	local perPlayer = ammo[player]
	if not perPlayer then
		perPlayer = {}
		ammo[player] = perPlayer
	end
	perPlayer[weaponId] = def and def.maxAmmo or 0
	return perPlayer[weaponId]
end

function AmmoLedger.clearPlayer(player: Player)
	ammo[player] = nil
end

return AmmoLedger
