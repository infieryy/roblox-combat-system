--!strict
--[[
    EquipService  (server)
    ----------------------
    Handles EquipRequest and UnequipRequest.

    Equip pipeline:
      1. Rate-limit.
      2. classify == "Weapon" and getWeaponId / def exist.
      3. Distance ≤ maxEquipDistance.
      4. Not already held by another player.
      5. PlayerHoldState.setWeapon → if previous hold was a Prop,
         call DragService.forceRelease (cross-service teardown contract).
      6. AmmoLedger.onEquip.
      7. Attach weapon to character (WeldConstraint to HumanoidRootPart).
      8. Fire EquipResult(true, weaponId, ammo) + HoldStateChanged is fired by
         PlayerHoldState.setWeapon automatically.

    Cross-service dependency: EquipService needs DragService.forceRelease.
    DragService needs EquipService.forceUnequip.
    Both are injected via setters after construction in init.server to break
    the circular require.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil") :: ModuleScript)
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger      = require(script.Parent.AmmoLedger)

-- Injected after construction to break circular require with DragService.
local _dragService: { forceRelease: (Player) -> () }? = nil

-- Per-player last equip timestamp for rate limiting.
local lastEquipAt: { [Player]: number } = {}
-- Per-player weld created on equip, stored for removal on unequip.
local equippedWelds: { [Player]: WeldConstraint } = {}

-- ---------------------------------------------------------------------------
-- Remotes
-- ---------------------------------------------------------------------------
local _remotes: { EquipResult: RemoteEvent }? = nil
local function getRemotes()
    if not _remotes then
        local folder = ReplicatedStorage:WaitForChild("ItemSystemRemotes")
        _remotes = { EquipResult = folder:WaitForChild("EquipResult") :: RemoteEvent }
    end
    return _remotes :: { EquipResult: RemoteEvent }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function getHumanoidRootPart(player: Player): BasePart?
    local character = player.Character
    if not character then return nil end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp :: BasePart end
    return nil
end

local function attachToCharacter(weapon: Instance, hrp: BasePart): WeldConstraint?
    local primary = GeometryUtil.getPrimaryPart(weapon)
    if not primary then return nil end

    -- Unanchor the weapon primary so the weld can work.
    primary.Anchored = false

    local weld = Instance.new("WeldConstraint")
    weld.Name  = "EquipWeld"
    weld.Part0 = hrp
    weld.Part1 = primary
    weld.Parent = hrp
    return weld
end

local function detachFromCharacter(player: Player)
    local weld = equippedWelds[player]
    if weld and weld.Parent then
        weld:Destroy()
    end
    equippedWelds[player] = nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local EquipService = {}

function EquipService.setDragService(svc: { forceRelease: (Player) -> () })
    _dragService = svc
end

function EquipService.onEquipRequest(player: Player, requested: unknown)
    -- Rate limiting.
    local now = os.clock()
    local last = lastEquipAt[player] or 0
    if (now - last) * 1000 < Config.Security.equipRequestCooldownMs then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end
    lastEquipAt[player] = now

    if typeof(requested) ~= "Instance" then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end
    local instance = requested :: Instance
    if not instance:IsDescendantOf(Workspace) then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end

    -- Must be classified as a weapon with a known WeaponId.
    if ItemRegistry.classify(instance) ~= "Weapon" then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end
    local weaponId = ItemRegistry.getWeaponId(instance)
    if not weaponId then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end
    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end

    -- Distance check (measures to visual centre).
    local hrp = getHumanoidRootPart(player)
    if not hrp then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end
    local centre   = GeometryUtil.getVisualCenter(instance)
    local distance = (centre - hrp.Position).Magnitude
    if distance > Config.Security.maxEquipDistance then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end

    -- Not already held by someone else.
    local heldBy = instance:GetAttribute(Config.HeldByAttribute)
    if heldBy ~= nil and heldBy ~= player.UserId then
        getRemotes().EquipResult:FireClient(player, false, nil, nil)
        return
    end

    -- One-item rule: register weapon hold; if previous was a Prop, force-release it.
    local prev = PlayerHoldState.setWeapon(player, instance, weaponId)
    if prev.kind == "Prop" and _dragService then
        _dragService.forceRelease(player)
    end

    AmmoLedger.onEquip(player, weaponId)
    local ammo = AmmoLedger.get(player, weaponId)

    -- Stamp ownership and attach.
    instance:SetAttribute(Config.HeldByAttribute, player.UserId)
    local weld = attachToCharacter(instance, hrp)
    if weld then
        equippedWelds[player] = weld
    end

    getRemotes().EquipResult:FireClient(player, true, weaponId, ammo)
end

function EquipService.onUnequipRequest(player: Player)
    EquipService.forceUnequip(player)
end

-- Called by DragService when a prop grab is initiated while a weapon is held.
function EquipService.forceUnequip(player: Player)
    local holdState = PlayerHoldState.get(player)
    if holdState.kind ~= "Weapon" then return end

    detachFromCharacter(player)

    local weapon = holdState.instance
    if weapon and weapon.Parent then
        weapon:SetAttribute(Config.HeldByAttribute, nil)
    end

    PlayerHoldState.clear(player)
    getRemotes().EquipResult:FireClient(player, false, nil, nil)
end

-- Clean up on player leaving.
Players.PlayerRemoving:Connect(function(player)
    detachFromCharacter(player)
    lastEquipAt[player] = nil
end)

return EquipService
