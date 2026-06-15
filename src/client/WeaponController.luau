--!strict
-- Module: WeaponController
-- Client-side shooting prediction, ammo reconciliation, tracers, and reload.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local RemotesClient = require(script.Parent.RemotesClient)
local ViewmodelController = require(script.Parent.ViewmodelController)

type RemotesClientTable = RemotesClient.RemotesClientTable

local WeaponController = {}

local remotes: RemotesClientTable? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local holdKind: string = "None"
local weaponId: string? = nil
local predictedAmmo = 0
local clientShotId = 0
local lastLocalFireTime = 0
local reloading = false

local ammoLabel: TextLabel? = nil

local function getAmmoLabel(): TextLabel
	if ammoLabel then
		return ammoLabel
	end
	local label = Instance.new("TextLabel")
	label.Name = "AmmoHUD"
	label.AnchorPoint = Vector2.new(1, 1)
	label.Position = UDim2.fromScale(0.97, 0.95)
	label.Size = UDim2.fromOffset(160, 36)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = ""
	label.Visible = false
	local ui = player:WaitForChild("PlayerGui"):FindFirstChild("ItemSystemUI")
	label.Parent = ui or player:WaitForChild("PlayerGui")
	ammoLabel = label
	return label
end

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function updateAmmoHud()
	local label = getAmmoLabel()
	if holdKind ~= "Weapon" or not weaponId then
		label.Visible = false
		return
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		label.Visible = false
		return
	end
	label.Visible = true
	local reloadText = if reloading then "  [Reloading]" else ""
	label.Text = string.format("%s  %d / %d%s", def.displayName, predictedAmmo, def.maxAmmo, reloadText)
end

local function spawnTracer(origin: Vector3, hitPosition: Vector3)
	local distance = (hitPosition - origin).Magnitude
	if distance < 0.05 then
		return
	end

	local tracer = Instance.new("Part")
	tracer.Name = "ShotTracer"
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 220, 120)
	tracer.Size = Vector3.new(Config.Weapon.tracerWidth, Config.Weapon.tracerWidth, distance)
	tracer.CFrame = CFrame.lookAt(origin, hitPosition) * CFrame.new(0, 0, -distance * 0.5)
	tracer.Parent = Workspace

	task.delay(Config.Weapon.tracerLifetime, function()
		if tracer.Parent then
			tracer:Destroy()
		end
	end)
end

local function canFireLocally(): boolean
	if holdKind ~= "Weapon" or not weaponId or reloading then
		return false
	end
	if predictedAmmo <= 0 then
		return false
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return false
	end
	local now = os.clock()
	if now - lastLocalFireTime < 1 / def.fireRateRps then
		return false
	end
	return true
end

local function predictFire()
	if not remotes or not weaponId then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end

	local origin = ViewmodelController.getMuzzlePosition()
	local direction = cam.CFrame.LookVector
	clientShotId += 1
	local shotId = clientShotId

	predictedAmmo = math.max(0, predictedAmmo - 1)
	lastLocalFireTime = os.clock()
	updateAmmoHud()

	ViewmodelController.playFireKick()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	if ViewmodelController.getMuzzlePosition() then
		local vm = Workspace.CurrentCamera and Workspace.CurrentCamera:FindFirstChild("LocalViewmodel")
		if vm then
			table.insert(filter, vm)
		end
	end
	rayParams.FilterDescendantsInstances = filter

	local def = ItemRegistry.getWeaponDef(weaponId)
	local range = if def then def.range else 200
	local result = Workspace:Raycast(origin, direction * range, rayParams)
	local hitPos = if result then result.Position else origin + direction * range
	spawnTracer(origin, hitPos)

	remotes.FireRequest:FireServer(origin, direction, shotId)
end

local function requestReload()
	if not remotes or holdKind ~= "Weapon" or not weaponId or reloading then
		return
	end
	reloading = true
	updateAmmoHud()
	remotes.ReloadRequest:FireServer()
end

function WeaponController.onHoldStateChanged(kind: string, newWeaponId: string?)
	holdKind = kind
	weaponId = newWeaponId
	reloading = false
	if kind ~= "Weapon" then
		predictedAmmo = 0
	end
	updateAmmoHud()
end

function WeaponController.onEquipResult(ok: boolean, newWeaponId: string?, ammo: number?)
	if ok and newWeaponId and ammo then
		holdKind = "Weapon"
		weaponId = newWeaponId
		predictedAmmo = ammo
		ViewmodelController.onEquip(newWeaponId)
	else
		if holdKind == "Weapon" then
			holdKind = "None"
			weaponId = nil
			predictedAmmo = 0
			ViewmodelController.onUnequip()
		end
	end
	updateAmmoHud()
end

function WeaponController.start(remotesTable: RemotesClientTable)
	remotes = remotesTable

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and holdKind == "Weapon" then
			if canFireLocally() then
				predictFire()
			end
			return
		end

		if input.KeyCode == Enum.KeyCode.R and holdKind == "Weapon" then
			requestReload()
		end
	end)

	remotesTable.EquipResult.OnClientEvent:Connect(function(ok: boolean, newWeaponId: string?, ammo: number?)
		WeaponController.onEquipResult(ok, newWeaponId, ammo)
	end)

	remotesTable.FireResult.OnClientEvent:Connect(function(
		returnedShotId: number,
		ok: boolean,
		ammo: number,
		hitPosition: Vector3?
	)
		if holdKind ~= "Weapon" then
			return
		end
		predictedAmmo = ammo
		updateAmmoHud()

		if not ok and returnedShotId == clientShotId then
			local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
			if def then
				predictedAmmo = math.min(def.maxAmmo, predictedAmmo + 1)
				updateAmmoHud()
			end
		elseif ok and hitPosition then
			local cam = getCamera()
			if cam then
				spawnTracer(ViewmodelController.getMuzzlePosition(), hitPosition)
			end
		end
	end)

	remotesTable.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
		reloading = false
		if ok then
			predictedAmmo = ammo
		end
		updateAmmoHud()
	end)

	remotesTable.ShotFired.OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hitPosition: Vector3)
		if shooter == player then
			return
		end
		spawnTracer(origin, hitPosition)
	end)

	remotesTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?, newWeaponId: string?)
		WeaponController.onHoldStateChanged(kind, newWeaponId)
		ViewmodelController.onHoldStateChanged(kind, newWeaponId)
		if kind ~= "Weapon" then
			ViewmodelController.onUnequip()
		end
	end)
end

return WeaponController
