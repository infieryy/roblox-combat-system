local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local WeaponDefinitions = require(CombatFolder:WaitForChild("WeaponDefinitions"))

local WeaponController = {}
WeaponController.__index = WeaponController

function WeaponController.new(remotes, viewmodelController, dragController)
	local self = setmetatable({}, WeaponController)
	self.remotes = remotes
	self.viewmodelController = viewmodelController
	self.dragController = dragController
	self.connections = {}

	self.equippedWeaponId = nil
	self.ammoByWeapon = {}
	self.isReloading = false

	self.isFireHeld = false
	self.singleShotQueued = false
	self.lastLocalFireAt = 0
	self.dragInfluenceTarget = 0
	self.dragInfluenceCurrent = 0

	return self
end

function WeaponController:applyServerState(payload)
	if typeof(payload) ~= "table" then
		return
	end

	if typeof(payload.ammoByWeapon) == "table" then
		self.ammoByWeapon = payload.ammoByWeapon
	end

	self.isReloading = payload.isReloading == true
	local nextWeaponId = payload.equippedWeaponId
	if nextWeaponId ~= self.equippedWeaponId then
		self.equippedWeaponId = nextWeaponId
		if self.equippedWeaponId then
			local definition = WeaponDefinitions.get(self.equippedWeaponId)
			self.viewmodelController:equip(self.equippedWeaponId, definition)
		else
			self.viewmodelController:unequip()
		end
	end
end

function WeaponController:attemptFire()
	if not self.equippedWeaponId then
		return
	end
	if self.isReloading then
		return
	end

	local weaponDefinition = WeaponDefinitions.get(self.equippedWeaponId)
	local currentAmmo = self.ammoByWeapon[self.equippedWeaponId]
	if currentAmmo ~= nil and currentAmmo <= 0 then
		return
	end

	local now = os.clock()
	local shotDelay = 1 / weaponDefinition.fireRate
	if now - self.lastLocalFireAt < shotDelay then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	self.lastLocalFireAt = now
	self.remotes.fireWeapon:FireServer({
		weaponId = self.equippedWeaponId,
		origin = camera.CFrame.Position,
		direction = camera.CFrame.LookVector,
		clientFiredAt = now,
	})
end

function WeaponController:requestReload()
	if not self.equippedWeaponId or self.isReloading then
		return
	end
	self.remotes.reloadWeapon:FireServer()
end

function WeaponController:onDragStarted(payload)
	if typeof(payload) ~= "table" then
		return
	end
	self.dragInfluenceTarget = 1
end

function WeaponController:onDragUpdated(payload)
	if typeof(payload) ~= "table" then
		return
	end
	self.dragInfluenceTarget = 1
end

function WeaponController:onDragEnded(payload)
	self.dragInfluenceTarget = 0
	if typeof(payload) ~= "table" then
		return
	end

	if payload.shouldEquip == true and typeof(payload.weaponId) == "string" then
		self.remotes.equipWeapon:FireServer(payload.weaponId)
	end
end

function WeaponController:processContinuousFire()
	if not self.equippedWeaponId then
		return
	end
	local definition = WeaponDefinitions.get(self.equippedWeaponId)
	if definition.canAutoFire then
		if self.isFireHeld then
			self:attemptFire()
		end
		return
	end

	if self.singleShotQueued then
		self.singleShotQueued = false
		self:attemptFire()
	end
end

function WeaponController:update(dt)
	self:processContinuousFire()

	local mouseDelta = UserInputService:GetMouseDelta()
	self.dragInfluenceCurrent = self.dragInfluenceCurrent + (self.dragInfluenceTarget - self.dragInfluenceCurrent) * math.min(1, dt * 16)
	self.viewmodelController:setDragInfluence(self.dragInfluenceCurrent)
	self.viewmodelController:update(dt, mouseDelta)
end

function WeaponController:start()
	table.insert(self.connections, self.remotes.weaponState.OnClientEvent:Connect(function(payload)
		self:applyServerState(payload)
	end))

	table.insert(self.connections, self.dragController:getDragStartedEvent().Event:Connect(function(payload)
		self:onDragStarted(payload)
	end))
	table.insert(self.connections, self.dragController:getDragUpdatedEvent().Event:Connect(function(payload)
		self:onDragUpdated(payload)
	end))
	table.insert(self.connections, self.dragController:getDragEndedEvent().Event:Connect(function(payload)
		self:onDragEnded(payload)
	end))

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.isFireHeld = true
			self.singleShotQueued = true
		elseif input.KeyCode == Enum.KeyCode.R then
			self:requestReload()
		elseif input.KeyCode == Enum.KeyCode.X then
			self.remotes.unequipWeapon:FireServer()
		end
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input, _gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.isFireHeld = false
		end
	end))

	table.insert(self.connections, RunService.RenderStepped:Connect(function(dt)
		self:update(dt)
	end))

	self.dragController:start()
end

function WeaponController:destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	self.dragController:destroy()
	self.viewmodelController:destroy()
end

return WeaponController
