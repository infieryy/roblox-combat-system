--!strict

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local WeaponController = {}

local remotes: any = nil
local viewmodelController: any = nil
local dragController: any = nil

local holdKind: "Weapon" | "Prop" | "None" = "None"
local currentWeaponId: string? = nil
local predictedAmmo: number = 0
local clientShotId = 0

local function canFire(): boolean
	if holdKind ~= "Weapon" or not currentWeaponId then
		return false
	end
	if dragController.isDragging() then
		return false
	end
	return true
end

local function fireWeapon()
	if not canFire() then
		return
	end

	local weaponDef = ItemRegistry.getWeaponDef(currentWeaponId :: string)
	if not weaponDef then
		return
	end

	if predictedAmmo <= 0 then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	clientShotId += 1
	local origin = viewmodelController.getMuzzlePosition()
	local direction = camera.CFrame.LookVector

	remotes.FireRequest:FireServer({
		clientShotId = clientShotId,
		weaponId = currentWeaponId,
		origin = origin,
		direction = direction,
	})

	predictedAmmo = math.max(0, predictedAmmo - 1)
	viewmodelController.onFireKick()
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.UserInputType == Config.Input.dragButton then
		fireWeapon()
		return
	end

	if input.KeyCode == Config.Input.reloadKey and canFire() and currentWeaponId then
		remotes.ReloadRequest:FireServer(currentWeaponId)
	end
end

local function onHoldStateChanged(state: any)
	if typeof(state) ~= "table" then
		return
	end
	holdKind = state.kind
	if state.kind == "Weapon" and typeof(state.weaponId) == "string" then
		currentWeaponId = state.weaponId
		local def = ItemRegistry.getWeaponDef(state.weaponId)
		predictedAmmo = if def then def.magazineSize else 0
	else
		currentWeaponId = nil
		predictedAmmo = 0
	end
end

local function onEquipResult(success: boolean, weaponId: any, ammo: any)
	viewmodelController.onEquipResult(success, weaponId)
	if success and typeof(weaponId) == "string" then
		currentWeaponId = weaponId
		holdKind = "Weapon"
		if typeof(ammo) == "number" then
			predictedAmmo = ammo
		end
	else
		currentWeaponId = nil
		predictedAmmo = 0
		if holdKind == "Weapon" then
			holdKind = "None"
		end
	end
end

local function onFireResult(success: boolean, _reason: string, _returnedShotId: any, ammo: any)
	if not success then
		if typeof(ammo) == "number" then
			predictedAmmo = ammo
		end
		return
	end
	if typeof(ammo) == "number" then
		predictedAmmo = ammo
	end
end

function WeaponController.start(remoteMap: any, viewmodel: any, drag: any)
	remotes = remoteMap
	viewmodelController = viewmodel
	dragController = drag

	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)
	remotes.EquipResult.OnClientEvent:Connect(onEquipResult)
	remotes.FireResult.OnClientEvent:Connect(onFireResult)

	UserInputService.InputBegan:Connect(onInputBegan)
end

return WeaponController
