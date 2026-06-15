--!strict
-- Module: WeaponController
-- Client-side weapon handling: predict fire, reconcile server ammo, tracer effects.
-- NEW — not in the consensus build.
--
-- Firing pipeline (client prediction model):
--   1. Mouse click while holding a weapon, off local cooldown, predicted ammo > 0.
--   2. Immediately: increment clientShotId, decrement predicted ammo, play fire effects.
--   3. Send FireRequest(origin, direction, clientShotId) to server.
--   4. On FireResult(id, ok, ammo, hitPos):
--        ok=true  → set ammo to authoritative value, show confirmed hit marker.
--        ok=false → roll back: restore ammo, clear effects for that shot.
--
-- Tracer / muzzle flash rendering uses simple Part instances parented to Workspace.
-- Replace these with proper particle effects in production.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local Remotes             = require(script.Parent:WaitForChild("RemotesClient"))
local ViewmodelController = require(script.Parent:WaitForChild("ViewmodelController"))

local WeaponController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

local isWeaponEquipped   = false
local equippedWeaponId: string? = nil
local predictedAmmo      = 0
local clientShotId       = 0
local lastLocalFireTime  = 0

-- Pending shot table for reconciliation: clientShotId → { ammoBeforeShot }
type PendingShot = { ammoBeforeShot: number }
local pendingShots: { [number]: PendingShot } = {}

-- HUD elements
local screenGui: ScreenGui? = nil
local ammoLabel: TextLabel? = nil
local reloadLabel: TextLabel? = nil
local isReloading = false

-- -------------------------------------------------------------------------
-- HUD
-- -------------------------------------------------------------------------

local function buildHUD()
	local gui = Instance.new("ScreenGui")
	gui.Name           = "WeaponHUD"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.Parent         = player:WaitForChild("PlayerGui")
	screenGui          = gui

	local ammo            = Instance.new("TextLabel")
	ammo.Name             = "AmmoDisplay"
	ammo.AnchorPoint      = Vector2.new(1, 1)
	ammo.Position         = UDim2.fromScale(0.97, 0.95)
	ammo.Size             = UDim2.fromOffset(160, 40)
	ammo.BackgroundTransparency = 1
	ammo.Font             = Enum.Font.GothamBold
	ammo.TextSize         = 28
	ammo.TextColor3       = Color3.fromRGB(255, 255, 255)
	ammo.TextStrokeTransparency = 0.4
	ammo.TextXAlignment   = Enum.TextXAlignment.Right
	ammo.Text             = ""
	ammo.Visible          = false
	ammo.Parent           = gui
	ammoLabel             = ammo

	local reload           = Instance.new("TextLabel")
	reload.Name            = "ReloadPrompt"
	reload.AnchorPoint     = Vector2.new(0.5, 0.5)
	reload.Position        = UDim2.fromScale(0.5, 0.58)
	reload.Size            = UDim2.fromOffset(200, 30)
	reload.BackgroundTransparency = 1
	reload.Font            = Enum.Font.GothamMedium
	reload.TextSize        = 18
	reload.TextColor3      = Color3.fromRGB(255, 240, 100)
	reload.TextStrokeTransparency = 0.4
	reload.Text            = "RELOADING..."
	reload.Visible         = false
	reload.Parent          = gui
	reloadLabel            = reload
end

local function updateAmmoHUD()
	if not ammoLabel then return end
	if isWeaponEquipped then
		local def = equippedWeaponId and ItemRegistry.getWeaponDef(equippedWeaponId)
		local maxAmmo = def and def.maxAmmo or 0
		ammoLabel.Text    = tostring(predictedAmmo) .. " / " .. tostring(maxAmmo)
		ammoLabel.Visible = true
	else
		ammoLabel.Visible = false
	end
end

-- -------------------------------------------------------------------------
-- Visual effects (placeholder implementations)
-- -------------------------------------------------------------------------

-- Draw a simple line tracer from origin to endpoint.
local function spawnTracer(from: Vector3, to: Vector3)
	local length    = (to - from).Magnitude
	if length < 0.01 then return end
	local midpoint  = (from + to) * 0.5
	local direction = (to - from).Unit

	local tracer    = Instance.new("Part")
	tracer.Name     = "BulletTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery   = false
	tracer.CanTouch   = false
	tracer.CastShadow = false
	tracer.Size       = Vector3.new(0.06, 0.06, length)
	tracer.CFrame     = CFrame.lookAt(midpoint, to) * CFrame.new(0, 0, -length * 0.5)
	tracer.BrickColor = BrickColor.new("Bright yellow")
	tracer.Material   = Enum.Material.Neon
	tracer.Parent     = Workspace

	game:GetService("Debris"):AddItem(tracer, 0.12)
end

-- Spawn a brief impact flash at a world position.
local function spawnImpact(pos: Vector3)
	local part          = Instance.new("Part")
	part.Name           = "BulletImpact"
	part.Anchored       = true
	part.CanCollide     = false
	part.CanQuery       = false
	part.CanTouch       = false
	part.CastShadow     = false
	part.Size           = Vector3.new(0.4, 0.4, 0.4)
	part.CFrame         = CFrame.new(pos)
	part.BrickColor     = BrickColor.new("Bright orange")
	part.Material       = Enum.Material.Neon
	part.Shape          = Enum.PartType.Ball
	part.Parent         = Workspace
	game:GetService("Debris"):AddItem(part, 0.08)
end

-- -------------------------------------------------------------------------
-- Fire
-- -------------------------------------------------------------------------

local function tryFire()
	if not isWeaponEquipped or not equippedWeaponId then return end
	if predictedAmmo <= 0 then
		-- Out of ammo — suggest reload
		if not isReloading then
			if reloadLabel then reloadLabel.Visible = true end
			task.delay(1.5, function()
				if reloadLabel then reloadLabel.Visible = false end
			end)
		end
		return
	end
	if isReloading then return end

	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then return end

	-- Client-side fire rate gate
	local now = os.clock()
	if now - lastLocalFireTime < (1 / def.fireRateRps) then return end
	lastLocalFireTime = now

	-- Client prediction
	clientShotId += 1
	local shotId          = clientShotId
	local ammoBeforeShot  = predictedAmmo
	predictedAmmo        -= 1
	updateAmmoHUD()

	pendingShots[shotId] = { ammoBeforeShot = ammoBeforeShot }

	-- Visual prediction effects
	camera = Workspace.CurrentCamera
	if not camera then return end
	local origin    = ViewmodelController.getMuzzlePosition()
	local direction = camera.CFrame.LookVector

	ViewmodelController.playFireKick()
	spawnTracer(origin, origin + direction * def.range)

	-- Send to server
	Remotes.FireRequest:FireServer(origin, direction, shotId)
end

-- -------------------------------------------------------------------------
-- Reload
-- -------------------------------------------------------------------------

local function tryReload()
	if not isWeaponEquipped or not equippedWeaponId then return end
	if isReloading then return end
	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then return end
	if predictedAmmo >= def.maxAmmo then return end

	isReloading = true
	if reloadLabel then reloadLabel.Visible = true end
	Remotes.ReloadRequest:FireServer()
end

-- -------------------------------------------------------------------------
-- Network handlers
-- -------------------------------------------------------------------------

Remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, ammo: number?)
	if ok and weaponId then
		isWeaponEquipped  = true
		equippedWeaponId  = weaponId
		predictedAmmo     = ammo or 0
		isReloading       = false
		pendingShots      = {}
		lastLocalFireTime = 0
		updateAmmoHUD()
	else
		isWeaponEquipped  = false
		equippedWeaponId  = nil
		predictedAmmo     = 0
		updateAmmoHUD()
	end
end)

Remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
	if kind ~= "Weapon" then
		isWeaponEquipped  = false
		equippedWeaponId  = nil
		predictedAmmo     = 0
		isReloading       = false
		if reloadLabel then reloadLabel.Visible = false end
		updateAmmoHUD()
	end
end)

Remotes.FireResult.OnClientEvent:Connect(function(
	serverShotId: number,
	ok: boolean,
	authoritative_ammo: number,
	hitPosition: Vector3?
)
	local pending = pendingShots[serverShotId]
	pendingShots[serverShotId] = nil

	if ok then
		-- Reconcile: accept server ammo as truth.
		predictedAmmo = authoritative_ammo
		if hitPosition then
			spawnImpact(hitPosition)
		end
	else
		-- Roll back: restore ammo to before this shot.
		if pending then
			predictedAmmo = pending.ammoBeforeShot
		end
		-- Also accept server ammo if it differs (desync recovery).
		if authoritative_ammo >= 0 then
			predictedAmmo = authoritative_ammo
		end
	end
	updateAmmoHUD()
end)

Remotes.ReloadResult.OnClientEvent:Connect(function(ok: boolean, newAmmo: number)
	isReloading = false
	if reloadLabel then reloadLabel.Visible = false end
	if ok then
		predictedAmmo = newAmmo
		updateAmmoHUD()
	end
end)

-- Broadcast from server: another player fired — show their tracer.
Remotes.ShotFired.OnClientEvent:Connect(function(_shooter: Player, origin: Vector3, hitPosition: Vector3)
	spawnTracer(origin, hitPosition)
	spawnImpact(hitPosition)
end)

-- -------------------------------------------------------------------------
-- Input
-- -------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if isWeaponEquipped then
			tryFire()
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.R then
		if isWeaponEquipped then
			tryReload()
		end
		return
	end
end)

-- Auto-fire on hold for full-auto weapons (fires each frame mouse is held).
local mouseHeld = false
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = true
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = false
	end
end)

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- start() called from init.client.luau after ViewmodelController.start().
function WeaponController.start(_viewmodelController: any)
	buildHUD()

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = Workspace.CurrentCamera
	end)

	player.CharacterAdded:Connect(function()
		isWeaponEquipped  = false
		equippedWeaponId  = nil
		predictedAmmo     = 0
		isReloading       = false
		pendingShots      = {}
		updateAmmoHUD()
	end)

	-- Heartbeat for full-auto: keep firing while mouse is held and weapon equipped.
	RunService.Heartbeat:Connect(function()
		if mouseHeld and isWeaponEquipped then
			local def = equippedWeaponId and ItemRegistry.getWeaponDef(equippedWeaponId)
			-- Only auto-fire if the weapon has a high fire rate (> 1 RPS semi-auto threshold).
			if def and def.fireRateRps > 1.5 then
				tryFire()
			end
		end
	end)
end

function WeaponController.isWeaponHeld(): boolean
	return isWeaponEquipped
end

return WeaponController
