--!strict
--[[
    AmmoLedger  (server)
    --------------------
    The ONLY module allowed to read or mutate ammo counts.
    Per-player, per-weapon tracking ensures no shared state leaks between
    multiple guns or multiple players.

    Anti-cheat guarantee: clients never send ammo values. They send intents
    (FireRequest, ReloadRequest); the server calls canFire/consumeRound/reload
    here and sends the authoritative count back.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

-- ledger[player][weaponId] = current ammo count
local ledger: { [Player]: { [string]: number } } = {}

local AmmoLedger = {}

local function getPlayerTable(player: Player): { [string]: number }
    if not ledger[player] then
        ledger[player] = {}
    end
    return ledger[player] :: { [string]: number }
end

-- Called when a player equips a weapon. Initialises ammo to maxAmmo on first
-- equip; subsequent re-equips of the same weapon preserve whatever ammo remains.
function AmmoLedger.onEquip(player: Player, weaponId: string)
    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then
        return
    end
    local t = getPlayerTable(player)
    if t[weaponId] == nil then
        t[weaponId] = def.maxAmmo
    end
end

-- Returns current ammo for a (player, weapon) pair. Returns 0 if unknown.
function AmmoLedger.get(player: Player, weaponId: string): number
    local t = ledger[player]
    if not t then
        return 0
    end
    return t[weaponId] or 0
end

-- Returns true if the player has at least 1 round of this weapon.
function AmmoLedger.canFire(player: Player, weaponId: string): boolean
    return AmmoLedger.get(player, weaponId) > 0
end

-- Decrements ammo by 1. Returns true on success, false if already at 0.
function AmmoLedger.consumeRound(player: Player, weaponId: string): boolean
    local t = getPlayerTable(player)
    local current = t[weaponId] or 0
    if current <= 0 then
        return false
    end
    t[weaponId] = current - 1
    return true
end

-- Refills ammo to maxAmmo. Returns new ammo count, or 0 if weapon is unknown.
function AmmoLedger.reload(player: Player, weaponId: string): number
    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then
        return 0
    end
    local t = getPlayerTable(player)
    t[weaponId] = def.maxAmmo
    return def.maxAmmo
end

-- Removes all ammo records for a player (called on PlayerRemoving or death).
function AmmoLedger.clearPlayer(player: Player)
    ledger[player] = nil
end

Players.PlayerRemoving:Connect(AmmoLedger.clearPlayer)

return AmmoLedger
