--!strict
-- Module: AmmoLedger
-- Server-authoritative ammo tracking. The ONLY module allowed to mutate ammo counts.
-- Blueprint §10.4.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

-- ledger[player][weaponId] = currentAmmo
local ledger: { [Player]: { [string]: number } } = {}

local AmmoLedger = {}

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------

function AmmoLedger.start()
	Players.PlayerRemoving:Connect(function(player: Player)
		ledger[player] = nil
	end)
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- Called when a player equips a weapon. Initialises to maxAmmo if this is
-- the player's first time equipping this weapon type.
function AmmoLedger.onEquip(player: Player, weaponId: string)
	if not ledger[player] then
		ledger[player] = {}
	end
	if ledger[player][weaponId] == nil then
		local def = ItemRegistry.getWeaponDef(weaponId)
		ledger[player][weaponId] = def and def.maxAmmo or 0
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	return (ledger[player] and ledger[player][weaponId]) or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

-- Consume one round. Returns true if a round was available and consumed.
function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	if not AmmoLedger.canFire(player, weaponId) then
		return false
	end
	ledger[player][weaponId] -= 1
	return true
end

-- Refill to maxAmmo. Returns the new ammo count.
function AmmoLedger.reload(player: Player, weaponId: string): number
	if not ledger[player] then
		ledger[player] = {}
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	local max = def and def.maxAmmo or 0
	ledger[player][weaponId] = max
	return max
end

function AmmoLedger.clearPlayer(player: Player)
	ledger[player] = nil
end

return AmmoLedger
