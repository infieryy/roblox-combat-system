--!strict
-- Module: Client weapon input, prediction, and reconciliation.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))
type RemotesClientModule = typeof(require(script.Parent.RemotesClient))
type ClientRemotes = RemotesClientModule.ClientRemotes

type ViewmodelApi = {
	playFireKick: () -> (),
	getMuzzlePosition: () -> Vector3?,
}

local WeaponController = {}

local localPlayer = Players.LocalPlayer
local started = false
local remotes: ClientRemotes? = nil
local viewmodel: ViewmodelApi? = nil

local holdKind: "Weapon" | "Prop" | "None" = "None"
local currentWeaponId: string? = nil
local predictedAmmo = 0
local lastFireAt = 0
local nextShotId = 0
local pendingShots: { [number]: boolean } = {}

local function drawTracer(origin: Vector3, hitPosition: Vector3, color: Color3)
	local segment = Instance.new("Part")
	segment.Name = "ShotTracer"
	segment.Anchored = true
	segment.CanCollide = false
	segment.CanQuery = false
	segment.Material = Enum.Material.Neon
	segment.Color = color
	segment.Size = Vector3.new(0.06, 0.06, (hitPosition - origin).Magnitude)
	segment.CFrame = CFrame.lookAt(origin, hitPosition) * CFrame.new(0, 0, -segment.Size.Z * 0.5)
	segment.Parent = workspace
	Debris:AddItem(segment, 0.08)
end

local function getWeaponDef()
	if not currentWeaponId then
		return nil
	end
	return ItemRegistry.getWeaponDef(currentWeaponId)
end

local function attemptFire()
	if holdKind ~= "Weapon" then
		return
	end
	if not remotes or not viewmodel then
		return
	end
	if not currentWeaponId then
		return
	end

	local weaponDef = getWeaponDef()
	if not weaponDef then
		return
	end
	if predictedAmmo <= 0 then
		return
	end

	local now = os.clock()
	local minGap = if weaponDef.fireRateRps > 0 then 1 / weaponDef.fireRateRps else 0
	if now - lastFireAt < minGap then
		return
	end
	lastFireAt = now

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	nextShotId += 1
	local shotId = nextShotId
	pendingShots[shotId] = true
	predictedAmmo -= 1

	local spread = weaponDef.spread
	local randomX = (math.random() - 0.5) * spread
	local randomY = (math.random() - 0.5) * spread
	local direction = (camera.CFrame.LookVector + Vector3.new(randomX, randomY, 0)).Unit
	local origin = camera.CFrame.Position

	viewmodel.playFireKick()
	local tracerEnd = origin + direction * math.min(weaponDef.range, 80)
	drawTracer(origin, tracerEnd, Color3.fromRGB(255, 245, 160))

	remotes.FireRequest:FireServer(origin, direction, shotId)
end

function WeaponController.start(remoteBundle: ClientRemotes, viewmodelApi: ViewmodelApi)
	if started then
		return
	end
	started = true
	remotes = remoteBundle
	viewmodel = viewmodelApi

	remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, ammo: number?)
		if not ok or not weaponId then
			return
		end
		holdKind = "Weapon"
		currentWeaponId = weaponId
		predictedAmmo = ammo or 0
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "Weapon" then
			holdKind = "Weapon"
		elseif kind == "Prop" or kind == "None" then
			holdKind = kind
			currentWeaponId = nil
			predictedAmmo = 0
			pendingShots = {}
		end
	end)

	remotes.FireResult.OnClientEvent:Connect(function(shotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
		pendingShots[shotId] = nil
		predictedAmmo = ammo
		if ok and hitPosition then
			local origin = viewmodel and viewmodel.getMuzzlePosition() or nil
			if not origin then
				local camera = workspace.CurrentCamera
				origin = if camera then camera.CFrame.Position else hitPosition
			end
			drawTracer(origin, hitPosition, Color3.fromRGB(255, 180, 80))
		end
	end)

	remotes.ShotFired.OnClientEvent:Connect(function(shooter: Player, origin: Vector3, hitPosition: Vector3)
		if shooter == localPlayer then
			return
		end
		drawTracer(origin, hitPosition, Color3.fromRGB(120, 210, 255))
	end)

	remotes.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
		if ok then
			predictedAmmo = ammo
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			attemptFire()
		elseif input.KeyCode == Config.Weapon.defaultReloadKey then
			if remotes and holdKind == "Weapon" then
				remotes.ReloadRequest:FireServer()
			end
		end
	end)
end

return WeaponController
