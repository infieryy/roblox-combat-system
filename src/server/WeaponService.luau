--!strict
--[[
    WeaponService  (server)
    -----------------------
    Handles FireRequest and ReloadRequest.

    FireRequest pipeline (anti-cheat at every step):
      1. Rate-limit per player.
      2. Verify PlayerHoldState == Weapon; resolve weaponId + def.
      3. Per-weapon fire-rate: server timestamp gap ≥ 1 / def.fireRateRps.
      4. AmmoLedger.canFire → consumeRound; else FireResult(id,false,0).
      5. Plausibility: angle(direction, real look-vector) ≤ maxAimDeviationDegrees.
      6. Origin near player head (within reasonable tolerance).
      7. Authoritative server raycast from trusted head origin along direction,
         length = def.range + serverRayLengthPadding, excluding shooter character.
         This enforces line-of-sight: shooting through walls is impossible.
      8. Damage humanoid if hit; fire FireResult(id,true,ammo,hitPos) and
         broadcast ShotFired to all clients for tracer/impact effects.

    ReloadRequest pipeline:
      1. Verify weapon held.
      2. Wait def.reloadTime on a task.delay (simple non-blocking).
      3. AmmoLedger.reload → ReloadResult.
      -- TODO(v2: lagcomp) — add lag compensation / rewind here if needed.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger      = require(script.Parent.AmmoLedger)

-- Per-player last-shot timestamps keyed by weaponId (fire-rate enforcement).
local lastShotAt:   { [Player]: { [string]: number } } = {}
-- Rate-limit timestamps for the FireRequest remote itself.
local lastFireReqAt: { [Player]: number } = {}
-- Per-player reload-in-progress guard.
local reloading: { [Player]: boolean } = {}

-- ---------------------------------------------------------------------------
-- Remotes
-- ---------------------------------------------------------------------------
local _remotes: {
    FireResult:  RemoteEvent,
    ShotFired:   RemoteEvent,
    ReloadResult:RemoteEvent,
}? = nil

local function getRemotes()
    if not _remotes then
        local f = ReplicatedStorage:WaitForChild("ItemSystemRemotes")
        _remotes = {
            FireResult   = f:WaitForChild("FireResult")   :: RemoteEvent,
            ShotFired    = f:WaitForChild("ShotFired")    :: RemoteEvent,
            ReloadResult = f:WaitForChild("ReloadResult") :: RemoteEvent,
        }
    end
    return _remotes :: { FireResult: RemoteEvent, ShotFired: RemoteEvent, ReloadResult: RemoteEvent }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function getHead(player: Player): BasePart?
    local character = player.Character
    if not character then return nil end
    local head = character:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head :: BasePart end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp :: BasePart end
    return nil
end

local function getPlayerShotTable(player: Player): { [string]: number }
    if not lastShotAt[player] then
        lastShotAt[player] = {}
    end
    return lastShotAt[player] :: { [string]: number }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local WeaponService = {}

function WeaponService.onFireRequest(
    player: Player,
    originRaw: unknown,
    directionRaw: unknown,
    clientShotIdRaw: unknown
)
    local remotes = getRemotes()

    -- Remote-level rate limit.
    local now = os.clock()
    local lastReq = lastFireReqAt[player] or 0
    if (now - lastReq) * 1000 < Config.Security.fireRequestCooldownMs then return end
    lastFireReqAt[player] = now

    -- Type guards.
    if typeof(originRaw) ~= "Vector3" or typeof(directionRaw) ~= "Vector3"
        or typeof(clientShotIdRaw) ~= "number" then
        return
    end
    local origin    = originRaw :: Vector3
    local direction = directionRaw :: Vector3
    local shotId    = clientShotIdRaw :: number

    -- Must have a weapon equipped.
    local holdState = PlayerHoldState.get(player)
    if holdState.kind ~= "Weapon" or not holdState.weaponId then
        remotes.FireResult:FireClient(player, shotId, false, 0, nil)
        return
    end
    local weaponId = holdState.weaponId :: string
    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then
        remotes.FireResult:FireClient(player, shotId, false, 0, nil)
        return
    end

    -- Per-weapon fire-rate enforcement.
    local shotTable = getPlayerShotTable(player)
    local lastShot  = shotTable[weaponId] or 0
    local minGap    = 1 / def.fireRateRps
    if (now - lastShot) < minGap then
        remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
        return
    end

    -- Ammo check.
    if not AmmoLedger.canFire(player, weaponId) then
        remotes.FireResult:FireClient(player, shotId, false, 0, nil)
        return
    end

    -- Direction plausibility: must be a valid unit vector.
    if direction.Magnitude < 0.01 then
        return
    end
    local unitDir = direction.Unit

    -- Aim-deviation check: client direction must be within maxAimDeviationDegrees
    -- of the player's real look vector (derived from the head's CFrame on the server).
    local head = getHead(player)
    if not head then
        remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
        return
    end
    local realLook = head.CFrame.LookVector
    local dot = math.clamp(realLook:Dot(unitDir), -1, 1)
    local deviationDeg = math.deg(math.acos(dot))
    if deviationDeg > Config.Weapon.maxAimDeviationDegrees then
        warn(string.format("[WeaponService] %s: aim deviation %.1f° > max %.1f° — rejected",
            player.Name, deviationDeg, Config.Weapon.maxAimDeviationDegrees))
        remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
        return
    end

    -- Origin plausibility: must be near the head (tight tolerance of 12 studs).
    local originDist = (origin - head.Position).Magnitude
    if originDist > 12 then
        warn(string.format("[WeaponService] %s: origin %0.1f studs from head — rejected", player.Name, originDist))
        return
    end

    -- Consume the round (authoritative).
    AmmoLedger.consumeRound(player, weaponId)
    shotTable[weaponId] = now
    local newAmmo = AmmoLedger.get(player, weaponId)

    -- Authoritative hitscan raycast from a trusted head position.
    -- Using head position (not client origin) prevents shoot-through-wall exploits.
    local character = player.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = character and { character } or {}
    params.IgnoreWater = true

    local rayLength = def.range + Config.Weapon.serverRayLengthPadding
    local rayResult = Workspace:Raycast(head.Position, unitDir * rayLength, params)

    local hitPosition: Vector3? = nil
    if rayResult then
        hitPosition = rayResult.Position
        local hitPart  = rayResult.Instance
        local hitModel = hitPart:FindFirstAncestorOfClass("Model")
        local humanoid = hitModel and hitModel:FindFirstChildOfClass("Humanoid")
        if humanoid and (humanoid :: Humanoid).Health > 0 then
            (humanoid :: Humanoid):TakeDamage(def.damage)
        end
    end

    -- Send authoritative result to the shooter.
    remotes.FireResult:FireClient(player, shotId, true, newAmmo, hitPosition)

    -- Broadcast to all clients for tracer / impact VFX.
    remotes.ShotFired:FireAllClients(player, head.Position, hitPosition or (head.Position + unitDir * def.range))
end

function WeaponService.onReloadRequest(player: Player)
    local remotes = getRemotes()

    if reloading[player] then return end

    local holdState = PlayerHoldState.get(player)
    if holdState.kind ~= "Weapon" or not holdState.weaponId then return end
    local weaponId = holdState.weaponId :: string
    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then return end

    -- Don't reload a full magazine.
    if AmmoLedger.get(player, weaponId) >= def.maxAmmo then return end

    reloading[player] = true
    task.delay(def.reloadTime, function()
        reloading[player] = nil
        -- Re-validate: player might have unequipped or died during the reload.
        local currentState = PlayerHoldState.get(player)
        if currentState.kind ~= "Weapon" or currentState.weaponId ~= weaponId then return end
        local newAmmo = AmmoLedger.reload(player, weaponId)
        if player.Parent then
            remotes.ReloadResult:FireClient(player, true, newAmmo)
        end
    end)
end

-- Clean up on player leaving.
Players.PlayerRemoving:Connect(function(player)
    lastShotAt[player]    = nil
    lastFireReqAt[player] = nil
    reloading[player]     = nil
end)

return WeaponService
