--!strict
-- Module: WeaponController
-- Client-side weapon firing, prediction, tracers, and HUD.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local RemotesClient = require(script.Parent.RemotesClient)
local InteractionController = require(script.Parent.InteractionController)
local ViewmodelController = require(script.Parent.ViewmodelController)
local DragController = require(script.Parent.DragController)

local WeaponController = {}

local player = Players.LocalPlayer
local remotes: RemotesClient.RemotesClientTable? = nil
local camera = Workspace.CurrentCamera

local equippedWeaponId: string? = nil
local predictedAmmo = 0
local nextClientShotId = 1
local lastLocalFireAt = 0
local reloading = false

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "AmmoLabel"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.new(1, -24, 1, -24)
ammoLabel.Size = UDim2.fromOffset(180, 36)
ammoLabel.BackgroundTransparency = 0.35
ammoLabel.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextSize = 22
ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ammoLabel.Text = ""
ammoLabel.Visible = false
ammoLabel.Parent = gui

local ammoCorner = Instance.new("UICorner")
ammoCorner.CornerRadius = UDim.new(0, 6)
ammoCorner.Parent = ammoLabel

local effectsFolder = Instance.new("Folder")
effectsFolder.Name = "WeaponEffects"
effectsFolder.Parent = Workspace

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function updateHud()
	if equippedWeaponId then
		local def = ItemRegistry.getWeaponDef(equippedWeaponId)
		local name = if def then def.displayName else equippedWeaponId
		ammoLabel.Text = string.format("%s  %d", name, predictedAmmo)
		ammoLabel.Visible = true
	else
		ammoLabel.Visible = false
	end
end

local function applySpread(direction: Vector3, spread: number): Vector3
	if spread <= 0 then
		return direction
	end
	local random = Random.new()
	local offset = Vector3.new(
		random:NextNumber(-spread, spread),
		random:NextNumber(-spread, spread),
		random:NextNumber(-spread, spread)
	)
	return (direction + offset).Unit
end

local function createTracer(origin: Vector3, hitPosition: Vector3)
	local distance = (hitPosition - origin).Magnitude
	local part = Instance.new("Part")
	part.Name = "Tracer"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 220, 120)
	part.Size = Vector3.new(0.08, 0.08, math.max(distance, 0.1))
	part.CFrame = CFrame.lookAt(origin, hitPosition) * CFrame.new(0, 0, -part.Size.Z * 0.5)
	part.Parent = effectsFolder
	game:GetService("Debris"):AddItem(part, Config.Weapon.tracerLifetime)
end

local function createImpact(position: Vector3)
	local impact = Instance.new("Part")
	impact.Name = "Impact"
	impact.Shape = Enum.PartType.Ball
	impact.Anchored = true
	impact.CanCollide = false
	impact.CanQuery = false
	impact.CanTouch = false
	impact.Material = Enum.Material.Neon
	impact.Color = Color3.fromRGB(255, 140, 60)
	impact.Size = Vector3.new(0.25, 0.25, 0.25)
	impact.Position = position
	impact.Parent = effectsFolder
	game:GetService("Debris"):AddItem(impact, Config.Weapon.impactLifetime)
end

local function createMuzzleFlash()
	local cam = getCamera()
	if not cam then
		return
	end
	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 240, 180)
	flash.Size = Vector3.new(0.35, 0.35, 0.35)
	flash.CFrame = CFrame.new(ViewmodelController.getMuzzlePosition())
	flash.Parent = effectsFolder
	game:GetService("Debris"):AddItem(flash, Config.Weapon.muzzleFlashLifetime)
end

local function localRaycast(origin: Vector3, direction: Vector3, range: number): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	local held = DragController.getHeldObject()
	if held then
		table.insert(filter, held)
	end
	if ViewmodelController.isVisible() then
		-- Cosmetic viewmodel should not block shots.
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction * range, params)
	if result then
		return result.Position
	end
	return origin + direction * range
end

local function canFireNow(): boolean
	if not equippedWeaponId or predictedAmmo <= 0 or reloading then
		return false
	end
	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		return false
	end
	local now = os.clock()
	return now - lastLocalFireAt >= (1 / def.fireRateRps)
end

local function fireWeapon()
	if not remotes or not equippedWeaponId then
		return
	end
	if InteractionController.getHoldKind() ~= "Weapon" then
		return
	end
	if not canFireNow() then
		return
	end

	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		return
	end

	local cam = getCamera()
	if not cam then
		return
	end

	local origin = ViewmodelController.getMuzzlePosition()
	local direction = applySpread(cam.CFrame.LookVector, def.spread)
	local hitPosition = localRaycast(origin, direction, def.range)
	local shotId = nextClientShotId
	nextClientShotId += 1

	predictedAmmo = math.max(0, predictedAmmo - 1)
	lastLocalFireAt = os.clock()
	updateHud()

	ViewmodelController.playFireKick()
	createMuzzleFlash()
	createTracer(origin, hitPosition)

	remotes.FireRequest:FireServer(origin, direction, shotId)
end

function WeaponController.onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not remotes then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if InteractionController.getHoldKind() == "Weapon" then
			fireWeapon()
		end
		return
	end

	if input.KeyCode == Config.Input.reloadKey then
		if equippedWeaponId and not reloading then
			reloading = true
			remotes.ReloadRequest:FireServer()
		end
	end
end

function WeaponController.start(remoteTable: RemotesClient.RemotesClientTable)
	remotes = remoteTable

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, ammo: number?)
		if ok and weaponId and ammo then
			equippedWeaponId = weaponId
			predictedAmmo = ammo
			reloading = false
		else
			equippedWeaponId = nil
			predictedAmmo = 0
			reloading = false
		end
		updateHud()
	end)

	remoteTable.FireResult.OnClientEvent:Connect(function(
		clientShotId: number,
		ok: boolean,
		ammo: number,
		hitPosition: Vector3?
	)
		if clientShotId > 0 then
			predictedAmmo = ammo
			updateHud()
		end
		if ok and hitPosition then
			createImpact(hitPosition)
		end
	end)

	remoteTable.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
		reloading = false
		if ok then
			predictedAmmo = ammo
			updateHud()
		end
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind == "Weapon" and weaponId then
			equippedWeaponId = weaponId
		else
			equippedWeaponId = nil
			predictedAmmo = 0
			reloading = false
		end
		updateHud()
	end)

	remoteTable.ShotFired.OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hitPosition: Vector3)
		if shooter == player then
			return
		end
		createTracer(origin, hitPosition)
		createImpact(hitPosition)
	end)

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera then
			camera = Workspace.CurrentCamera
		end
	end)

	updateHud()
end

return WeaponController
