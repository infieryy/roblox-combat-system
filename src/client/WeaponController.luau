--!strict
-- Module: client/WeaponController
-- New. Predicts firing locally for snappy feel, then reconciles against the
-- server's authoritative FireResult. Sends only (origin, direction, shotId).
-- Renders tracers/impacts (own + others via ShotFired), handles reload, and
-- draws the ammo HUD.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

local WpnCfg = Config.Weapon

local WeaponController = {}

local ctx: Context = nil :: any
local player = Players.LocalPlayer

local currentKind = "None"
local weaponId: string? = nil
local def: any = nil
local predictedAmmo = 0
local reloading = false

local firing = false -- left mouse held
local lastShotClock = 0
local shotCounter = 0

----------------------------------------------------------------------
-- HUD.
----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "Ammo"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.new(1, -28, 1, -24)
ammoLabel.Size = UDim2.fromOffset(220, 48)
ammoLabel.BackgroundTransparency = 1
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextSize = 34
ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ammoLabel.TextStrokeTransparency = 0.4
ammoLabel.Text = ""
ammoLabel.Parent = gui

local nameLabel = Instance.new("TextLabel")
nameLabel.Name = "WeaponName"
nameLabel.AnchorPoint = Vector2.new(1, 1)
nameLabel.Position = UDim2.new(1, -28, 1, -72)
nameLabel.Size = UDim2.fromOffset(260, 24)
nameLabel.BackgroundTransparency = 1
nameLabel.Font = Enum.Font.GothamMedium
nameLabel.TextSize = 18
nameLabel.TextXAlignment = Enum.TextXAlignment.Right
nameLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
nameLabel.TextStrokeTransparency = 0.5
nameLabel.Text = ""
nameLabel.Parent = gui

local function updateHud()
	if currentKind == "Weapon" and def then
		gui.Enabled = true
		nameLabel.Text = def.displayName
		if reloading then
			ammoLabel.Text = "RELOADING"
		else
			ammoLabel.Text = string.format("%d / %d", predictedAmmo, def.maxAmmo)
		end
	else
		gui.Enabled = false
	end
end

----------------------------------------------------------------------
-- FX.
----------------------------------------------------------------------

local function drawTracer(from: Vector3, to: Vector3)
	local distance = (to - from).Magnitude
	if distance < 0.1 then
		return
	end
	local tracer = Instance.new("Part")
	tracer.Name = "Tracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 226, 150)
	tracer.Size = Vector3.new(WpnCfg.tracerWidth, WpnCfg.tracerWidth, distance)
	tracer.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -distance / 2)
	tracer.Parent = Workspace
	Debris:AddItem(tracer, WpnCfg.tracerLifetime)
end

local function drawImpact(position: Vector3)
	local impact = Instance.new("Part")
	impact.Name = "Impact"
	impact.Anchored = true
	impact.CanCollide = false
	impact.CanQuery = false
	impact.CanTouch = false
	impact.CastShadow = false
	impact.Shape = Enum.PartType.Ball
	impact.Material = Enum.Material.Neon
	impact.Color = Color3.fromRGB(255, 200, 120)
	impact.Size = Vector3.new(0.3, 0.3, 0.3)
	impact.CFrame = CFrame.new(position)
	impact.Parent = Workspace
	Debris:AddItem(impact, WpnCfg.impactLifetime)
end

----------------------------------------------------------------------
-- Firing.
----------------------------------------------------------------------

local function tryFire()
	if currentKind ~= "Weapon" or not def or reloading then
		return
	end
	local now = os.clock()
	local minInterval = 1 / math.max(def.fireRateRps, 0.01)
	if now - lastShotClock < minInterval then
		return
	end
	if predictedAmmo <= 0 then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	lastShotClock = now
	predictedAmmo -= 1
	shotCounter += 1
	local shotId = shotCounter

	-- Cosmetic spread (kept well within the server plausibility cone).
	local spread = math.min(def.spread or 0, 0.05)
	local dir = cam.CFrame.LookVector
	if spread > 0 then
		dir = (cam.CFrame * CFrame.Angles((math.random() - 0.5) * spread, (math.random() - 0.5) * spread, 0)).LookVector
	end
	local origin = cam.CFrame.Position

	-- Predict the visual impact point with a local raycast.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	rayParams.FilterDescendantsInstances = filter
	local result = Workspace:Raycast(origin, dir * def.range, rayParams)
	local impactPoint = result and result.Position or (origin + dir * def.range)

	-- Local feedback.
	ctx.viewmodel.playFireKick()
	local muzzle = ctx.viewmodel.getMuzzlePosition() or origin
	drawTracer(muzzle, impactPoint)

	-- Tell the server (it re-validates everything and owns ammo).
	ctx.remotes.FireRequest:FireServer(origin, dir, shotId)

	updateHud()
end

----------------------------------------------------------------------
-- Net handlers.
----------------------------------------------------------------------

local function onEquipResult(ok: boolean, id: string?, ammo: number?)
	if ok and id then
		weaponId = id
		def = ItemRegistry.getWeaponDef(id)
		predictedAmmo = ammo or (def and def.maxAmmo) or 0
		currentKind = "Weapon"
		reloading = false
		updateHud()
	end
end

local function onHoldStateChanged(kind: string, instance: Instance?)
	currentKind = kind or "None"
	if currentKind == "Weapon" and instance then
		local id = ItemRegistry.getWeaponId(instance)
		if id then
			weaponId = id
			def = ItemRegistry.getWeaponDef(id)
		end
	else
		weaponId = nil
		def = nil
		firing = false
		reloading = false
	end
	updateHud()
end

local function onFireResult(_shotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
	-- Server is authoritative for ammo.
	predictedAmmo = ammo
	if ok and hitPosition then
		drawImpact(hitPosition)
	end
	updateHud()
end

local function onShotFired(shooter: Player, origin: Vector3, hitPosition: Vector3)
	if shooter == player then
		return
	end
	drawTracer(origin, hitPosition)
	drawImpact(hitPosition)
end

local function onReloadResult(ok: boolean, ammo: number)
	reloading = false
	if ok then
		predictedAmmo = ammo
	end
	updateHud()
end

local function requestReload()
	if currentKind ~= "Weapon" or not def or reloading then
		return
	end
	if predictedAmmo >= def.maxAmmo then
		return
	end
	reloading = true
	updateHud()
	ctx.remotes.ReloadRequest:FireServer()
end

----------------------------------------------------------------------
-- Input.
----------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Config.Input.gamepadFireButton then
		if currentKind == "Weapon" then
			firing = true
			tryFire() -- immediate first shot
		end
	elseif input.KeyCode == Config.Input.reloadKey or input.KeyCode == Config.Input.gamepadReloadKey then
		requestReload()
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.KeyCode == Config.Input.gamepadFireButton then
		firing = false
	end
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

function WeaponController.start(context: Context)
	ctx = context

	ctx.remotes.EquipResult.OnClientEvent:Connect(onEquipResult)
	ctx.remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)
	ctx.remotes.FireResult.OnClientEvent:Connect(onFireResult)
	ctx.remotes.ShotFired.OnClientEvent:Connect(onShotFired)
	ctx.remotes.ReloadResult.OnClientEvent:Connect(onReloadResult)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	player.CharacterAdded:Connect(function()
		firing = false
		reloading = false
		currentKind = "None"
		def = nil
		updateHud()
	end)

	-- Automatic fire while the button is held.
	RunService.Heartbeat:Connect(function()
		if firing then
			tryFire()
		end
	end)
end

return WeaponController
