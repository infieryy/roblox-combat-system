--!strict
--[[
    WeaponController  (client)
    --------------------------
    Handles the client side of equipping, firing, and reloading.

    Equip / unequip:
      • Sends EquipRequest(weapon) to server when InteractionController routes E-key.
      • On EquipResult(true): arms the controller with weaponId + authoritative ammo.
      • On EquipResult(false) / HoldStateChanged("None"): disarms.

    Fire (client prediction):
      • attemptFire() — called by InteractionController on LMB while weapon equipped.
      • If conditions pass (equipped, off cooldown, predicted ammo > 0):
          - Decrement predicted ammo.
          - Call viewmodelController.playFireKick() for visual response.
          - Raycast from camera (client-side, cosmetic hit for tracer).
          - Send FireRequest(origin, direction, clientShotId) to server.
      • On FireResult: set ammo to authoritative value; if ok=false, no VFX rollback
        needed (sound already played) but HUD updates.

    Reload:
      • R key sends ReloadRequest.
      • On ReloadResult: update predicted ammo.

    ShotFired (other players):
      • Simple broadcast; render a tracer line for spectators.

    Key bindings owned here:
      • R key → ReloadRequest
    InteractionController owns LMB (fire route) and E (equip route) to keep
    routing logic centralised.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

local RemotesClient        = require(script.Parent.RemotesClient)
local ViewmodelController  = require(script.Parent.ViewmodelController)

local localPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local currentWeaponId:  string? = nil
local predictedAmmo:    number  = 0
local lastShotAt:       number  = 0
local nextShotId:       number  = 1
-- Pending shots waiting for FireResult (for reconciliation).
local pendingShots: { [number]: { predicted: number } } = {}

local connections: { RBXScriptConnection } = {}

-- ---------------------------------------------------------------------------
-- HUD helpers (minimal: a simple ScreenGui label for ammo)
-- ---------------------------------------------------------------------------
local ammoLabel: TextLabel? = nil

local function ensureHud()
    if ammoLabel then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "WeaponHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = localPlayer:WaitForChild("PlayerGui")

    local label = Instance.new("TextLabel")
    label.Name = "AmmoLabel"
    label.AnchorPoint = Vector2.new(1, 1)
    label.Position = UDim2.new(1, -20, 1, -20)
    label.Size = UDim2.fromOffset(140, 34)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 22
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextStrokeTransparency = 0.4
    label.TextXAlignment = Enum.TextXAlignment.Right
    label.Text = ""
    label.Visible = false
    label.Parent = gui
    ammoLabel = label
end

local function updateAmmoHud()
    ensureHud()
    local label = ammoLabel
    if not label then return end
    if currentWeaponId then
        local def = ItemRegistry.getWeaponDef(currentWeaponId :: string)
        local maxAmmo = def and def.maxAmmo or 0
        label.Text = string.format("%d / %d", predictedAmmo, maxAmmo)
        label.Visible = true
    else
        label.Text = ""
        label.Visible = false
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local WeaponController = {}

function WeaponController.isEquipped(): boolean
    return currentWeaponId ~= nil
end

-- Called by InteractionController when LMB is pressed while a weapon is equipped.
function WeaponController.attemptFire()
    if not currentWeaponId then return end
    local def = ItemRegistry.getWeaponDef(currentWeaponId :: string)
    if not def then return end

    -- Client-side fire-rate guard (matches server check).
    local now = os.clock()
    local minGap = 1 / def.fireRateRps
    if (now - lastShotAt) < minGap then return end

    -- Client-side ammo guard.
    if predictedAmmo <= 0 then
        -- Trigger reload automatically on empty click.
        WeaponController.requestReload()
        return
    end

    lastShotAt = now
    local shotId = nextShotId
    nextShotId += 1

    -- Client prediction: decrement ammo immediately.
    predictedAmmo -= 1
    pendingShots[shotId] = { predicted = predictedAmmo }
    updateAmmoHud()

    -- Kick the viewmodel.
    ViewmodelController.playFireKick()

    -- Compute ray from camera/muzzle.
    local camera = Workspace.CurrentCamera
    local origin = ViewmodelController.getMuzzlePosition()
    local direction = camera.CFrame.LookVector

    -- Fire the request.
    local R = RemotesClient.get()
    R.FireRequest:FireServer(origin, direction, shotId)
end

function WeaponController.requestReload()
    if not currentWeaponId then return end
    local def = ItemRegistry.getWeaponDef(currentWeaponId :: string)
    if not def then return end
    if predictedAmmo >= def.maxAmmo then return end
    local R = RemotesClient.get()
    R.ReloadRequest:FireServer()
end

function WeaponController.sendEquipRequest(weapon: Instance)
    local R = RemotesClient.get()
    R.EquipRequest:FireServer(weapon)
end

function WeaponController.sendUnequipRequest()
    local R = RemotesClient.get()
    R.UnequipRequest:FireServer()
end

function WeaponController.start()
    ensureHud()
    local R = RemotesClient.get()

    -- Server confirms / rejects equip.
    table.insert(connections,
        R.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: unknown, ammo: unknown)
            if ok and typeof(weaponId) == "string" and typeof(ammo) == "number" then
                currentWeaponId = weaponId :: string
                predictedAmmo   = ammo :: number
                lastShotAt      = 0
                table.clear(pendingShots)
            else
                currentWeaponId = nil
                predictedAmmo   = 0
            end
            updateAmmoHud()
        end)
    )

    -- Authoritative hold state from server overrides prediction.
    table.insert(connections,
        R.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: unknown)
            if kind == "None" or kind == "Prop" then
                currentWeaponId = nil
                predictedAmmo   = 0
                table.clear(pendingShots)
                updateAmmoHud()
            end
        end)
    )

    -- Server result for a shot: reconcile ammo.
    table.insert(connections,
        R.FireResult.OnClientEvent:Connect(function(
            clientShotId: number,
            ok: boolean,
            authAmmo: number,
            hitPosition: Vector3?
        )
            pendingShots[clientShotId] = nil
            predictedAmmo = authAmmo
            updateAmmoHud()

            if ok and hitPosition then
                -- TODO(v1): render local hit marker / sound here.
            end
        end)
    )

    -- Other players fired — render their tracer.
    table.insert(connections,
        R.ShotFired.OnClientEvent:Connect(function(
            shooter: Player,
            origin: Vector3,
            hitPos: Vector3
        )
            if shooter == localPlayer then return end
            -- Draw a brief beam from origin to hitPos.
            -- Uses a Part-based tracer for simplicity; swap for a Beam if desired.
            task.spawn(function()
                local tracer = Instance.new("Part")
                tracer.Anchored = true
                tracer.CanCollide = false
                tracer.CanQuery   = false
                tracer.CanTouch   = false
                tracer.Size = Vector3.new(0.05, 0.05, (hitPos - origin).Magnitude)
                tracer.CFrame = CFrame.lookAt(origin, hitPos) * CFrame.new(0, 0, -(hitPos - origin).Magnitude * 0.5)
                tracer.Color = Color3.fromRGB(255, 240, 160)
                tracer.Material = Enum.Material.Neon
                tracer.Transparency = 0.3
                tracer.Parent = Workspace
                task.wait(0.08)
                tracer:Destroy()
            end)
        end)
    )

    -- Reload result.
    table.insert(connections,
        R.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
            if ok then
                predictedAmmo = ammo
                updateAmmoHud()
            end
        end)
    )

    -- R key → reload.
    table.insert(connections,
        UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
            if gameProcessed then return end
            if input.KeyCode == Enum.KeyCode.R then
                WeaponController.requestReload()
            end
        end)
    )
end

function WeaponController.destroy()
    for _, c in connections do c:Disconnect() end
    table.clear(connections)
end

return WeaponController
