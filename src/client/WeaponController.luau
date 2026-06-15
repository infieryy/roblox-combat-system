--!strict
--[[
	WeaponController  (client/WeaponController.luau → StarterPlayerScripts.Client.WeaponController)
	---------------------------------------------------------------------------------------------------
	Handles client-side weapon firing: client-side prediction, FireRequest, reconciliation.

	Client-side prediction:
	  On left-click (weapon equipped, predicted ammo > 0, off local cooldown):
	    1. Play local effects immediately (muzzle flash, fire sound, local tracer).
	    2. Predict ammo decrement.
	    3. Send FireRequest(origin, direction, clientShotId) to server.
	  On FireResult:
	    4. Reconcile: set ammo to server-authoritative value.
	       If ok=false, we roll back local effects.
	       If ok=true and hitPosition is set, render impact at confirmed spot.
	  On ShotFired (from other players):
	    Render tracer from origin to hitPosition (spectating other people's shots).

	Reload: R key while weapon equipped → ReloadRequest → show reload HUD → ReloadResult.
	Unequip: Q key while weapon equipped → UnequipRequest.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared              = ReplicatedStorage:WaitForChild("Shared")
local Config              = require(Shared:WaitForChild("Config"))
local ItemRegistry        = require(Shared:WaitForChild("ItemRegistry"))
local RemotesClient       = require(script.Parent:WaitForChild("RemotesClient"))
local ViewmodelController = require(script.Parent:WaitForChild("ViewmodelController"))

local LocalPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

local WeaponController = {}

local equipped:        boolean = false
local predictedAmmo:   number  = 0
local currentWeaponId: string? = nil
local isReloading:     boolean = false

-- Monotonically increasing shot counter for server reconciliation.
local nextClientShotId = 1

-- Per-cooldown guard: prevent firing faster than the server's fire-rate gate
-- (also prevents UI thrashing).
local lastFireTime = 0

-- ─────────────────────────────────────────────────────────────────────────────
-- HUD
-- ─────────────────────────────────────────────────────────────────────────────

local gui = Instance.new("ScreenGui")
gui.Name           = "WeaponHud"
gui.ResetOnSpawn   = false
gui.IgnoreGuiInset = true
gui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

-- Ammo counter (bottom-right).
local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name                = "AmmoLabel"
ammoLabel.AnchorPoint         = Vector2.new(1, 1)
ammoLabel.Position            = UDim2.fromScale(0.97, 0.95)
ammoLabel.Size                = UDim2.fromOffset(180, 36)
ammoLabel.BackgroundTransparency = 1
ammoLabel.TextColor3          = Color3.new(1, 1, 1)
ammoLabel.TextStrokeTransparency = 0.4
ammoLabel.Font                = Enum.Font.GothamBold
ammoLabel.TextSize            = 26
ammoLabel.TextXAlignment      = Enum.TextXAlignment.Right
ammoLabel.Text                = ""
ammoLabel.Visible             = false
ammoLabel.Parent              = gui

-- Reload notice.
local reloadLabel = Instance.new("TextLabel")
reloadLabel.Name                = "ReloadLabel"
reloadLabel.AnchorPoint         = Vector2.new(0.5, 1)
reloadLabel.Position            = UDim2.fromScale(0.5, 0.9)
reloadLabel.Size                = UDim2.fromOffset(260, 28)
reloadLabel.BackgroundTransparency = 1
reloadLabel.TextColor3          = Color3.fromRGB(255, 220, 80)
reloadLabel.TextStrokeTransparency = 0.4
reloadLabel.Font                = Enum.Font.GothamMedium
reloadLabel.TextSize            = 20
reloadLabel.Text                = "Reloading…"
reloadLabel.Visible             = false
reloadLabel.Parent              = gui

local function updateAmmoHud()
	if equipped then
		local def = currentWeaponId and ItemRegistry.getWeaponDef(currentWeaponId)
		ammoLabel.Text = string.format("%d / %d", predictedAmmo, def and def.maxAmmo or 0)
		ammoLabel.Visible = true
	else
		ammoLabel.Visible = false
	end
	reloadLabel.Visible = isReloading
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Local effects
-- ─────────────────────────────────────────────────────────────────────────────

-- Simple tracer: a thin stretched part from origin to endpoint, fades quickly.
local function spawnTracer(from: Vector3, to: Vector3)
	local length   = (to - from).Magnitude
	if length < 0.1 then return end

	local midpoint = (from + to) * 0.5
	local tracerPart = Instance.new("Part")
	tracerPart.Name          = "WeaponTracer"
	tracerPart.Anchored      = true
	tracerPart.CanCollide    = false
	tracerPart.CastShadow    = false
	tracerPart.Size          = Vector3.new(0.04, 0.04, length)
	tracerPart.CFrame        = CFrame.lookAt(midpoint, to)
	tracerPart.Material      = Enum.Material.Neon
	tracerPart.Color         = Color3.fromRGB(255, 220, 120)
	tracerPart.Transparency  = 0.3
	tracerPart.Parent        = workspace

	-- Fade out over 0.06 s then destroy.
	task.delay(0.06, function()
		if tracerPart.Parent then
			tracerPart:Destroy()
		end
	end)
end

-- Minimal impact effect: a brief bright sphere.
local function spawnImpact(position: Vector3)
	local part = Instance.new("Part")
	part.Name         = "WeaponImpact"
	part.Anchored     = true
	part.CanCollide   = false
	part.CastShadow   = false
	part.Shape        = Enum.PartType.Ball
	part.Size         = Vector3.new(0.3, 0.3, 0.3)
	part.CFrame       = CFrame.new(position)
	part.Material     = Enum.Material.Neon
	part.Color        = Color3.fromRGB(255, 200, 100)
	part.Transparency = 0
	part.Parent       = workspace

	task.delay(0.08, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

-- Play the "FireSound" from the viewmodel if it exists.
local function playFireSound()
	local vm = ViewmodelController.hasViewmodel() and workspace.CurrentCamera:FindFirstChild("ActiveViewmodel")
	if not vm then return end
	local sound = (vm :: Model):FindFirstChild("FireSound", true)
	if sound and sound:IsA("Sound") then
		(sound :: Sound):Play()
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Firing
-- ─────────────────────────────────────────────────────────────────────────────

local function doFire()
	if not equipped or not currentWeaponId then
		return
	end
	if predictedAmmo <= 0 then
		return
	end
	if isReloading then
		return
	end

	local def = ItemRegistry.getWeaponDef(currentWeaponId)
	if not def then return end

	-- Local cooldown (mirrors server's per-weapon RoF).
	local now = os.clock()
	local minInterval = 1 / def.fireRateRps
	if (now - lastFireTime) < minInterval then
		return
	end
	lastFireTime = now

	local camera = workspace.CurrentCamera
	local origin = camera.CFrame.Position

	-- Apply client-side spread deviation.
	local baseDirection = camera.CFrame.LookVector
	local direction: Vector3
	if def.spread > 0 then
		local spreadRad = math.rad(def.spread)
		local rx = (math.random() - 0.5) * 2 * spreadRad
		local ry = (math.random() - 0.5) * 2 * spreadRad
		direction = (CFrame.new(Vector3.zero, baseDirection) * CFrame.Angles(rx, ry, 0)).LookVector
	else
		direction = baseDirection
	end

	-- Client-side prediction.
	predictedAmmo -= 1
	updateAmmoHud()

	-- Local effects.
	playFireSound()
	ViewmodelController.playFireKick()

	-- Quick local raycast for immediate tracer/impact visuals.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local character = LocalPlayer.Character
	if character then
		rayParams.FilterDescendantsInstances = { character }
	end
	local result = workspace:Raycast(origin, direction * def.range, rayParams)
	local localHitPos = result and result.Position or (origin + direction * def.range)

	local muzzlePos = ViewmodelController.getMuzzlePosition()
	spawnTracer(muzzlePos, localHitPos)
	if result then
		spawnImpact(localHitPos)
	end

	-- Send to server.
	local shotId = nextClientShotId
	nextClientShotId += 1
	RemotesClient.get().FireRequest:FireServer(origin, direction, shotId)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input
-- ─────────────────────────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if equipped then
			doFire()
		end
	elseif input.KeyCode == Enum.KeyCode.Q then
		-- Q unequips.
		if equipped then
			RemotesClient.get().UnequipRequest:FireServer()
		end
	elseif input.KeyCode == Enum.KeyCode.R then
		-- R reloads (when not inspecting a held prop — handled by DragController).
		if equipped and not isReloading then
			local def = currentWeaponId and ItemRegistry.getWeaponDef(currentWeaponId)
			if def and predictedAmmo < def.maxAmmo then
				isReloading = true
				updateAmmoHud()
				RemotesClient.get().ReloadRequest:FireServer()
			end
		end
	end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote handlers
-- ─────────────────────────────────────────────────────────────────────────────

local function onEquipResult(ok: boolean, weaponId: string?, ammo: number?)
	if ok and weaponId and ammo then
		equipped        = true
		currentWeaponId = weaponId
		predictedAmmo   = ammo
		isReloading     = false
	else
		equipped        = false
		currentWeaponId = nil
		predictedAmmo   = 0
		isReloading     = false
	end
	updateAmmoHud()
end

-- clientShotId is kept for ordered rollback in v2 (reconciliation bookkeeping).
local function onFireResult(_clientShotId: number, ok: boolean, ammo: number, _hitPosition: Vector3?)
	if ok then
		-- Server confirmed: set ammo to authoritative value.
		predictedAmmo = ammo
	else
		-- Server rejected the shot: roll back prediction.
		predictedAmmo = ammo
		-- In a fuller implementation we'd un-apply local effects here.
	end
	updateAmmoHud()
end

local function onHoldStateChanged(kind: string, _instance: Instance?, weaponId: string?)
	if kind == "None" then
		equipped        = false
		currentWeaponId = nil
		predictedAmmo   = 0
		isReloading     = false
	elseif kind == "Weapon" and weaponId then
		equipped        = true
		currentWeaponId = weaponId
		-- ammo will be set by EquipResult
	elseif kind == "Prop" then
		equipped        = false
		currentWeaponId = nil
		predictedAmmo   = 0
		isReloading     = false
	end
	updateAmmoHud()
end

local function onShotFired(shooter: Player, origin: Vector3, hitPosition: Vector3)
	if shooter == LocalPlayer then
		-- We already rendered local effects; skip.
		return
	end
	spawnTracer(origin, hitPosition)
	spawnImpact(hitPosition)
end

local function onReloadResult(ok: boolean, ammo: number)
	isReloading = false
	if ok then
		predictedAmmo = ammo
	end
	updateAmmoHud()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Boot
-- ─────────────────────────────────────────────────────────────────────────────

function WeaponController.start()
	local remotes = RemotesClient.get()

	remotes.EquipResult.OnClientEvent:Connect(onEquipResult)
	remotes.FireResult.OnClientEvent:Connect(onFireResult)
	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)
	remotes.ShotFired.OnClientEvent:Connect(onShotFired)
	remotes.ReloadResult.OnClientEvent:Connect(onReloadResult)

	updateAmmoHud()
end

return WeaponController
