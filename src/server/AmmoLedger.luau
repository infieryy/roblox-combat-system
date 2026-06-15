--!strict
-- Module: AmmoLedger
-- Authoritative ammo tracking. The ONLY module allowed to mutate ammo counts.
-- Anti-cheat core: the client may predict ammo locally but the server's ledger
-- is the source of truth sent back via FireResult / ReloadResult.
--
-- Per-player, per-weapon isolation means carrying two weapons with different
-- ammo counts works correctly (though the one-item rule currently prevents that).

local ItemRegistry = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local AmmoLedger = {}

-- ledger[player][weaponId] = current ammo count
type AmmoTable = { [string]: number }
local ledger: { [Player]: AmmoTable } = {}

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------

-- Called by EquipService when a player successfully equips a weapon.
-- Initialises ammo to maxAmmo the FIRST time a weapon is equipped this session;
-- subsequent equips of the same weapon preserve the remaining ammo (no free refill on re-equip).
function AmmoLedger.onEquip(player: Player, weaponId: string)
	if not ledger[player] then
		ledger[player] = {}
	end
	if ledger[player][weaponId] == nil then
		local def = ItemRegistry.getWeaponDef(weaponId)
		ledger[player][weaponId] = def and def.maxAmmo or 0
	end
end

-- Called on PlayerRemoving to free memory.
function AmmoLedger.clearPlayer(player: Player)
	ledger[player] = nil
end

-- -------------------------------------------------------------------------
-- Read
-- -------------------------------------------------------------------------

function AmmoLedger.get(player: Player, weaponId: string): number
	return (ledger[player] and ledger[player][weaponId]) or 0
end

function AmmoLedger.canFire(player: Player, weaponId: string): boolean
	return AmmoLedger.get(player, weaponId) > 0
end

-- -------------------------------------------------------------------------
-- Mutate
-- -------------------------------------------------------------------------

-- Deduct one round. Returns true on success, false if out of ammo.
function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
	if not AmmoLedger.canFire(player, weaponId) then
		return false
	end
	ledger[player][weaponId] -= 1
	return true
end

-- Refill to maxAmmo. Returns the new ammo count.
function AmmoLedger.reload(player: Player, weaponId: string): number
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return 0
	end
	if not ledger[player] then
		ledger[player] = {}
	end
	ledger[player][weaponId] = def.maxAmmo
	return def.maxAmmo
end

return AmmoLedger
