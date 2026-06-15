--!strict
-- Module: WeaponController
-- Client-side weapon input, prediction, HUD, and effects.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)

local ViewmodelController = require(script.Parent.ViewmodelController)

type Remotes = typeof(require(script.Parent.RemotesClient).waitForRemotes())

local WeaponController = {}

local remotes: Remotes? = nil
local player = Players.LocalPlayer

local equippedWeaponId: string? = nil
local predictedAmmo = 0
local nextShotId = 1
local lastLocalFireAt = 0
local reloading = false

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "AmmoLabel"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.new(1, -24, 1, -24)
ammoLabel.Size = UDim2.fromOffset(180, 36)
ammoLabel.BackgroundTransparency = 0.35
ammoLabel.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextSize = 20
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
	return Workspace.CurrentCamera
end

local function updateAmmoHud()
	if not equippedWeaponId then
		ammoLabel.Visible = false
		return
	end
	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		ammoLabel.Visible = false
		return
	end
	ammoLabel.Visible = true
	ammoLabel.Text = string.format("%s  %d / %d", def.displayName, predictedAmmo, def.maxAmmo)
end

local function clearWeaponState()
	equippedWeaponId = nil
	predictedAmmo = 0
	reloading = false
	updateAmmoHud()
end

local function setEquipped(weaponId: string, ammo: number)
	equippedWeaponId = weaponId
	predictedAmmo = ammo
	reloading = false
	updateAmmoHud()
end

local function spawnTracer(origin: Vector3, hitPosition: Vector3)
	local distance = (hitPosition - origin).Magnitude
	if distance < 0.05 then
		return
	end

	local part = Instance.new("Part")
	part.Name = "Tracer"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 220, 120)
	part.Size = Vector3.new(0.08, 0.08, distance)
	part.CFrame = CFrame.lookAt(origin, hitPosition) * CFrame.new(0, 0, -distance * 0.5)
	part.Parent = effectsFolder

	task.delay(Config.Weapon.tracerLifetime, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local function spawnImpact(position: Vector3)
	local part = Instance.new("Part")
	part.Name = "Impact"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 140, 60)
	part.Size = Vector3.new(0.25, 0.25, 0.25)
	part.CFrame = CFrame.new(position)
	part.Parent = effectsFolder

	task.delay(Config.Weapon.impactLifetime, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local function predictShot(origin: Vector3, direction: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local weaponId = equippedWeaponId
	local range = 200
	if weaponId then
		local def = ItemRegistry.getWeaponDef(weaponId)
		if def then
			range = def.range
		end
	end

	local unitDirection = direction.Magnitude > 0 and direction.Unit or Vector3.new(0, 0, -1)
	local result = Workspace:Raycast(origin, unitDirection * range, params)
	local hitPosition = if result then result.Position else origin + unitDirection * range
	spawnTracer(origin, hitPosition)
	spawnImpact(hitPosition)
	ViewmodelController.playFireKick()
end

local function tryFire()
	if not remotes or not equippedWeaponId or reloading then
		return
	end
	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		return
	end
	if predictedAmmo <= 0 then
		return
	end

	local now = os.clock()
	local minInterval = 1 / def.fireRateRps
	if now - lastLocalFireAt < minInterval then
		return
	end
	lastLocalFireAt = now

	local cam = getCamera()
	if not cam then
		return
	end

	local origin = ViewmodelController.getMuzzlePosition()
	local direction = cam.CFrame.LookVector
	local shotId = nextShotId
	nextShotId += 1

	predictedAmmo -= 1
	updateAmmoHud()
	predictShot(origin, direction)

	remotes.FireRequest:FireServer(origin, direction, shotId)
end

local function tryReload()
	if not remotes or not equippedWeaponId or reloading then
		return
	end
	reloading = true
	remotes.ReloadRequest:FireServer()
end

function WeaponController.start(remoteTable: Remotes)
	remotes = remoteTable

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, ammo: number?)
		if ok and weaponId and ammo then
			setEquipped(weaponId, ammo)
		else
			clearWeaponState()
		end
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind == "None" then
			clearWeaponState()
		elseif kind == "Weapon" and weaponId then
			if not equippedWeaponId then
				setEquipped(weaponId, predictedAmmo)
			end
		end
	end)

	remoteTable.FireResult.OnClientEvent:Connect(function(clientShotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
		predictedAmmo = ammo
		updateAmmoHud()
		if not ok then
			return
		end
		if hitPosition and equippedWeaponId then
			local origin = ViewmodelController.getMuzzlePosition()
			spawnTracer(origin, hitPosition)
			spawnImpact(hitPosition)
		end
		clientShotId :: number -- used for reconciliation bookkeeping
	end)

	remoteTable.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
		reloading = false
		if ok then
			predictedAmmo = ammo
			updateAmmoHud()
		end
	end)

	remoteTable.ShotFired.OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hitPosition: Vector3)
		if shooter == player then
			return
		end
		spawnTracer(origin, hitPosition)
		spawnImpact(hitPosition)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if not equippedWeaponId then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			tryFire()
		elseif input.KeyCode == Enum.KeyCode.R then
			tryReload()
		end
	end)
end

return WeaponController
