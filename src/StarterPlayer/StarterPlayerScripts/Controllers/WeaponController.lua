local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponDefinitions = require(Shared:WaitForChild("Weapons"):WaitForChild("WeaponDefinitions"))

local WeaponController = {}
WeaponController.__index = WeaponController

function WeaponController.new(remotesFolder, dragController, viewmodelController)
	local self = setmetatable({}, WeaponController)
	self.remotes = remotesFolder
	self.dragController = dragController
	self.viewmodelController = viewmodelController
	self.currentWeaponId = "rifle"
	self.lastShotAt = 0
	self.connections = {}
	return self
end

function WeaponController:_equipWeapon(weaponId)
	local weaponData = WeaponDefinitions.getWeapon(weaponId)
	if not weaponData then
		return
	end

	self.currentWeaponId = weaponId
	self.remotes.EquipWeapon:FireServer(weaponId)
	self.viewmodelController:EquipWeapon(weaponId)
end

function WeaponController:_attemptFire()
	if self.dragController:IsDragging() then
		return
	end

	local weaponData = WeaponDefinitions.getWeapon(self.currentWeaponId)
	if not weaponData then
		return
	end

	local now = os.clock()
	if now - self.lastShotAt < weaponData.cooldown then
		return
	end
	self.lastShotAt = now

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	local origin = camera.CFrame:PointToWorldSpace(weaponData.muzzleOffset.Position)
	local direction = ray.Direction.Unit

	self.remotes.FireWeapon:FireServer(self.currentWeaponId, origin, direction)
end

function WeaponController:Start()
	self:_equipWeapon(self.currentWeaponId)
	self.viewmodelController:Start()

	self.connections.inputBegan = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_attemptFire()
			return
		end

		if input.KeyCode == Enum.KeyCode.One then
			self:_equipWeapon("rifle")
			return
		end

		if input.KeyCode == Enum.KeyCode.Two then
			self:_equipWeapon("pistol")
		end
	end)
end

function WeaponController:Destroy()
	for _, connection in pairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}
end

return WeaponController
