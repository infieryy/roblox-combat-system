--!strict
-- Module: client/WeaponController.luau

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)
local ViewmodelController = require(script.Parent.ViewmodelController)
local DragController = require(script.Parent.DragController)

local WeaponController = {}

local remotes: {
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ShotFired: RemoteEvent,
	ReloadRequest: RemoteEvent,
	ReloadResult: RemoteEvent,
	EquipResult: RemoteEvent,
	HoldStateChanged: RemoteEvent,
}? = nil

local player = Players.LocalPlayer
local equippedWeaponId: string? = nil
local predictedAmmo = 0
local nextClientShotId = 1
local lastLocalFireAt = 0
local reloading = false

local ammoLabel: TextLabel? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function setAmmoText()
	if ammoLabel then
		if equippedWeaponId then
			local def = ItemRegistry.getWeaponDef(equippedWeaponId)
			local name = if def then def.displayName else equippedWeaponId
			ammoLabel.Text = string.format("%s  |  %d", name, predictedAmmo)
			ammoLabel.Visible = true
		else
			ammoLabel.Visible = false
		end
	end
end

local function createHud()
	local gui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "WeaponHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Ammo"
	label.AnchorPoint = Vector2.new(1, 1)
	label.Position = UDim2.new(1, -24, 1, -24)
	label.Size = UDim2.fromOffset(260, 32)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.Visible = false
	label.Parent = screen
	ammoLabel = label
end

local function renderTracer(origin: Vector3, hitPosition: Vector3)
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
	part.CFrame = CFrame.lookAt(origin, hitPosition) * CFrame.new(0, 0, -distance * 0.5)
	part.Parent = Workspace
	task.delay(Config.Weapon.tracerLifetime, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local function canFireLocally(): boolean
	if not equippedWeaponId or reloading or predictedAmmo <= 0 then
		return false
	end
	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		return false
	end
	local now = os.clock()
	return now - lastLocalFireAt >= (1 / def.fireRateRps)
end

function WeaponController.tryFire()
	if not remotes or not equippedWeaponId or not canFireLocally() then
		return false
	end
	if DragController.isDragging() then
		return false
	end

	local camera = getCamera()
	if not camera then
		return false
	end

	local def = ItemRegistry.getWeaponDef(equippedWeaponId)
	if not def then
		return false
	end

	local origin = ViewmodelController.getMuzzlePosition()
	local direction = camera.CFrame.LookVector
	local shotId = nextClientShotId
	nextClientShotId += 1
	lastLocalFireAt = os.clock()

	predictedAmmo -= 1
	setAmmoText()
	ViewmodelController.playFireKick()
	renderTracer(origin, origin + direction * math.min(def.range, 120))

	remotes.FireRequest:FireServer(origin, direction, shotId)
	return true
end

function WeaponController.tryReload()
	if not remotes or not equippedWeaponId or reloading then
		return
	end
	reloading = true
	remotes.ReloadRequest:FireServer()
end

function WeaponController.isWeaponEquipped(): boolean
	return equippedWeaponId ~= nil
end

function WeaponController.onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		WeaponController.tryFire()
	elseif input.KeyCode == Config.Input.reloadKey then
		WeaponController.tryReload()
	end
end

function WeaponController.configure(remoteTable: typeof(remotes))
	remotes = remoteTable
	if not remotes then
		return
	end

	remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, ammo: number?)
		if ok and weaponId and ammo then
			equippedWeaponId = weaponId
			predictedAmmo = ammo
		else
			equippedWeaponId = nil
			predictedAmmo = 0
			reloading = false
		end
		setAmmoText()
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind ~= "Weapon" then
			equippedWeaponId = nil
			predictedAmmo = 0
			reloading = false
			setAmmoText()
		elseif weaponId then
			equippedWeaponId = weaponId
		end
	end)

	remotes.FireResult.OnClientEvent:Connect(function(clientShotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
		predictedAmmo = ammo
		setAmmoText()
		if ok and hitPosition then
			local origin = ViewmodelController.getMuzzlePosition()
			renderTracer(origin, hitPosition)
		elseif not ok then
			-- Server rejected; authoritative ammo already sent.
		end
		if clientShotId > 0 then
			-- keep shot id stream aligned
		end
	end)

	remotes.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
		reloading = false
		if ok then
			predictedAmmo = ammo
			setAmmoText()
		end
	end)

	remotes.ShotFired.OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hitPosition: Vector3)
		if shooter ~= player then
			renderTracer(origin, hitPosition)
		end
	end)
end

function WeaponController.start()
	createHud()
end

return WeaponController
