--!strict
-- Module: server/AmmoLedger
-- The authoritative, SOLE ammo mutator (BLUEPRINT.md §10.4, anti-cheat core).
-- No other module is allowed to change ammo. Ammo is tracked per player and per
-- weaponId so switching back to a previously-equipped weapon keeps its count.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local AmmoLedger = {}

-- ammo[player][weaponId] = roundsRemaining
local ammo: { [Player]: { [string]: number } } = {}

local function ledgerFor(player: Player): { [string]: number }
	local existing = ammo[player]
	if not existing then
		existing = {}
		ammo[player] = existing
	end
	return existing
end

-- Initialise to maxAmmo the first time this player equips this weapon; keep the
-- existing count on a re-equip.
function AmmoLedger.onEquip(player: Player, weaponId: string)
	local ledger = ledgerFor(player)
	if ledger[weaponId] == nil then
		local def = ItemRegistry.getWeaponDef(weaponId)
		ledger[weaponId] = def and def.maxAmmo or 0
	end
end

function AmmoLedger.get(player: Player, weaponId: string): number
	local ledger = ammo[player]
	if not ledger then
		return 0
	end
	return ledger[weaponId] or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

-- Consume a single round; returns true if a round was actually consumed.
function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	local ledger = ledgerFor(player)
	local current = ledger[weaponId] or 0
	if current <= 0 then
		return false
	end
	ledger[weaponId] = current - 1
	return true
end

-- Refill to the weapon's maxAmmo; returns the new count.
function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	local maxAmmo = def and def.maxAmmo or 0
	ledgerFor(player)[weaponId] = maxAmmo
	return maxAmmo
end

function AmmoLedger.clearPlayer(player: Player)
	ammo[player] = nil
end

return AmmoLedger
