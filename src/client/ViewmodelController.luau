--!strict
--[[
    ViewmodelController  (client)
    -----------------------------
    Owns first-person lock and the camera-space arms+gun viewmodel.

    State machine: Empty ↔ Weapon
      • On EquipResult(true, weaponId)  / HoldStateChanged("Weapon") → build + show viewmodel.
      • On EquipResult(false) / HoldStateChanged("None")             → hide + destroy viewmodel.

    Each RenderStepped:
      1. Base: camera.CFrame * Config.Viewmodel.baseOffset
      2. Layer look-sway: camera-rotation delta smoothed via lerp
         (mouse delta supplied by DragController.getSmoothedDelta — same delta
          as dbc1 branch, so weapon reacts to aiming movement naturally).
      3. Layer walk-bob: sine × humanoid move-speed so arms gently bob when walking.
      4. Layer fire-kick: decaying pitch kick played by playFireKick().
      Final CFrame = base * bobOffset * swayOffset * kickOffset

    The viewmodel Model is cloned from ReplicatedStorage.Assets.Viewmodels.<name>.
    If that asset doesn't exist, a minimal fallback gun shape is constructed so
    the system works in Studio without custom assets.

    Public API (called by WeaponController and InteractionController):
      equip(weaponId)        — build and show arms+gun for this weapon
      unequip()              — hide and destroy viewmodel
      getMuzzlePosition()    — world-space muzzle tip (for WeaponController origin)
      playFireKick()         — apply one frame of kick recoil
      isEquipped()           — true while a weapon viewmodel is visible
]]

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace      = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

local RemotesClient = require(script.Parent.RemotesClient)

local localPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- Fallback viewmodel builder (no Studio assets needed)
-- ---------------------------------------------------------------------------
local function buildFallbackViewmodel(weaponName: string): Model
    local model = Instance.new("Model")
    model.Name = weaponName

    local root = Instance.new("Part")
    root.Name = "Root"
    root.Size = Vector3.new(0.35, 0.35, 0.35)
    root.Anchored = true
    root.CanCollide = false
    root.CanQuery   = false
    root.CanTouch   = false
    root.Transparency = 1
    root.Parent = model
    model.PrimaryPart = root

    local body = Instance.new("Part")
    body.Name = "Body"
    body.Size = Vector3.new(0.2, 0.2, 1.2)
    body.Color = Color3.fromRGB(30, 30, 30)
    body.Material = Enum.Material.Metal
    body.Anchored = true
    body.CanCollide = false
    body.CanQuery   = false
    body.CanTouch   = false
    body.CFrame = root.CFrame * CFrame.new(0, 0, -0.6)
    body.Parent = model

    local wc = Instance.new("WeldConstraint")
    wc.Part0 = root
    wc.Part1 = body
    wc.Parent = body

    -- Muzzle marker (transparent, used by getMuzzlePosition).
    local muzzle = Instance.new("Part")
    muzzle.Name = "Muzzle"
    muzzle.Size = Vector3.new(0.1, 0.1, 0.1)
    muzzle.Anchored = true
    muzzle.CanCollide = false
    muzzle.CanQuery   = false
    muzzle.CanTouch   = false
    muzzle.Transparency = 1
    muzzle.CFrame = root.CFrame * CFrame.new(0, 0, -1.3)
    muzzle.Parent = model

    local wc2 = Instance.new("WeldConstraint")
    wc2.Part0 = root
    wc2.Part1 = muzzle
    wc2.Parent = muzzle

    return model
end

local function getOrBuildViewmodel(weaponName: string): Model
    local assets   = ReplicatedStorage:FindFirstChild("Assets")
    local vms      = assets and (assets :: Folder):FindFirstChild("Viewmodels")
    local template = vms and (vms :: Folder):FindFirstChild(weaponName)
    if template and template:IsA("Model") then
        return (template :: Model):Clone()
    end
    return buildFallbackViewmodel(weaponName)
end

local function prepareViewmodel(vm: Model)
    -- Make all parts anchored (positioned by PivotTo each frame) and non-collidable.
    for _, desc in vm:GetDescendants() do
        if desc:IsA("BasePart") then
            local bp = desc :: BasePart
            bp.Anchored    = true
            bp.CanCollide  = false
            bp.CanQuery    = false
            bp.CanTouch    = false
        end
    end
    -- Ensure PrimaryPart exists.
    if not vm.PrimaryPart then
        local firstPart = vm:FindFirstChildWhichIsA("BasePart", true)
        if firstPart then
            vm.PrimaryPart = firstPart :: BasePart
        end
    end
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local viewmodel: Model? = nil
local currentWeaponId: string? = nil

local currentSway      = CFrame.new()
local bobTime          = 0.0
local kickOffset       = 0.0    -- decaying pitch kick in radians
local prevCamRotation  = CFrame.new()  -- used to compute per-frame delta
local connections: { RBXScriptConnection } = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local ViewmodelController = {}

function ViewmodelController.isEquipped(): boolean
    return viewmodel ~= nil
end

function ViewmodelController.equip(weaponId: string)
    ViewmodelController.unequip()

    local def = ItemRegistry.getWeaponDef(weaponId)
    if not def then
        warn("[ViewmodelController] Unknown weaponId:", weaponId)
        return
    end
    currentWeaponId = weaponId

    local vm = getOrBuildViewmodel(def.viewmodelName)
    prepareViewmodel(vm)
    vm.Parent = Workspace.CurrentCamera
    viewmodel = vm
end

function ViewmodelController.unequip()
    if viewmodel then
        viewmodel:Destroy()
        viewmodel = nil
    end
    currentWeaponId = nil
    currentSway   = CFrame.new()
    kickOffset    = 0.0
    bobTime       = 0.0
end

-- Returns the world-space muzzle position, or the camera position as a fallback.
function ViewmodelController.getMuzzlePosition(): Vector3
    local vm = viewmodel
    if vm then
        local muzzle = vm:FindFirstChild("Muzzle", true)
        if muzzle and muzzle:IsA("BasePart") then
            return (muzzle :: BasePart).Position
        end
        -- Use the weapondef muzzle offset if no Muzzle part.
        local def = currentWeaponId and ItemRegistry.getWeaponDef(currentWeaponId :: string)
        if def then
            local cam = Workspace.CurrentCamera
            return cam.CFrame:PointToWorldSpace(def.muzzleOffset.Position)
        end
    end
    return Workspace.CurrentCamera.CFrame.Position
end

-- Called by WeaponController immediately on client-side fire prediction.
function ViewmodelController.playFireKick()
    kickOffset = Config.Viewmodel.kickAmount
end

function ViewmodelController.start()
    local R = RemotesClient.get()

    -- EquipResult: the server either confirmed or rejected the equip.
    table.insert(connections,
        R.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: unknown, _ammo: unknown)
            if ok and typeof(weaponId) == "string" then
                ViewmodelController.equip(weaponId :: string)
            else
                ViewmodelController.unequip()
            end
        end)
    )

    -- HoldStateChanged: authoritative override from server.
    table.insert(connections,
        R.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: unknown)
            if kind == "None" or kind == "Prop" then
                ViewmodelController.unequip()
            end
            -- "Weapon" is handled via EquipResult (which carries the weaponId).
        end)
    )

    -- First-person lock (ported from consensus; ViewmodelController owns this).
    localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

    -- Ensure new CurrentCamera gets the viewmodel reparented.
    Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        local vm = viewmodel
        if vm and Workspace.CurrentCamera then
            vm.Parent = Workspace.CurrentCamera
        end
    end)

    -- Main render loop.
    table.insert(connections,
        RunService.RenderStepped:Connect(function(dt: number)
            local vm = viewmodel
            if not vm then return end

            local camera = Workspace.CurrentCamera
            if not camera then return end

            -- Re-parent if needed (e.g. camera was recreated).
            if vm.Parent ~= camera then
                vm.Parent = camera
            end

            local def = currentWeaponId and ItemRegistry.getWeaponDef(currentWeaponId :: string)
            if not def then return end

            -----------------------------------------------------------------
            -- 1. Look-sway from camera rotation delta
            --    We compute the per-frame camera-rotation change and map that
            --    to a gentle tilt of the viewmodel (same technique as dbc1 but
            --    driven by actual camera delta instead of a drag smoothing feed).
            -----------------------------------------------------------------
            local camRot = camera.CFrame.Rotation
            local deltaCF = prevCamRotation:Inverse() * camRot
            prevCamRotation = camRot

            -- Extract yaw/pitch components from the delta CFrame.
            local dx, dy, _ = deltaCF:ToEulerAnglesXYZ()
            -- Clamp to avoid huge frame-one spike.
            local clampX = math.clamp(dx, -0.3, 0.3)
            local clampY = math.clamp(dy, -0.3, 0.3)

            local swayTarget = CFrame.Angles(
                -clampX * Config.Viewmodel.mouseSwayScale * 100,
                -clampY * Config.Viewmodel.mouseSwayScale * 100,
                0
            )
            currentSway = currentSway:Lerp(swayTarget,
                math.clamp(dt * Config.Viewmodel.mouseSwayLerpSpeed, 0, 1))

            -----------------------------------------------------------------
            -- 2. Walk-bob from character horizontal speed
            -----------------------------------------------------------------
            local character = localPlayer.Character
            local hrp = character and (character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?
            local speed = if hrp then (hrp :: BasePart).AssemblyLinearVelocity.Magnitude else 0
            local isMoving = speed > 0.5

            if isMoving then
                bobTime += dt * Config.Viewmodel.bobSpeed
            else
                -- Decay back towards zero so the bob doesn't freeze mid-swing.
                bobTime = bobTime * math.max(0, 1 - dt * 5)
            end
            local bobY = math.abs(math.sin(bobTime)) * Config.Viewmodel.bobAmount
            local bobX = math.sin(bobTime * 0.5) * Config.Viewmodel.bobAmount * 0.5
            local bobOffset = CFrame.new(bobX, bobY, 0)

            -----------------------------------------------------------------
            -- 3. Fire kick: decaying pitch recoil
            -----------------------------------------------------------------
            kickOffset = kickOffset * math.max(0, 1 - dt * Config.Viewmodel.kickRecoverySpeed)
            local kickCF = CFrame.Angles(-kickOffset, 0, 0)

            -----------------------------------------------------------------
            -- 4. Combine: base * bob * sway * kick
            -----------------------------------------------------------------
            local targetCF = camera.CFrame
                * Config.Viewmodel.baseOffset
                * bobOffset
                * currentSway
                * kickCF
            vm:PivotTo(targetCF)
        end)
    )
end

function ViewmodelController.destroy()
    ViewmodelController.unequip()
    for _, c in connections do c:Disconnect() end
    table.clear(connections)
end

return ViewmodelController
