local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local DragController = {}
DragController.__index = DragController

type DragPayload = {
	weaponId: string,
	worldPosition: Vector3?,
	shouldEquip: boolean?,
	target: Instance?,
}

export type DragControllerType = {
	start: (self: DragControllerType) -> (),
	stop: (self: DragControllerType) -> (),
	destroy: (self: DragControllerType) -> (),
	getDragStartedEvent: (self: DragControllerType) -> BindableEvent,
	getDragUpdatedEvent: (self: DragControllerType) -> BindableEvent,
	getDragEndedEvent: (self: DragControllerType) -> BindableEvent,
}

local DRAGGABLE_TAG = "DraggableWeapon"
local DRAG_UPDATE_INTERVAL = 1 / 20
local DEFAULT_DRAG_DISTANCE = 12

local function getCamera(): Camera
	local camera = workspace.CurrentCamera
	if not camera then
		camera = workspace:WaitForChild("Camera") :: Camera
	end
	return camera
end

local function getMouseRay(maxDistance: number): (Vector3, Vector3)
	local camera = getCamera()
	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return ray.Origin, ray.Direction.Unit * maxDistance
end

local function findDraggableTarget(instance: Instance?): Instance?
	local cursor: Instance? = instance
	while cursor do
		if cursor:GetAttribute("WeaponId") ~= nil then
			return cursor
		end
		if CollectionService:HasTag(cursor, DRAGGABLE_TAG) then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function getWeaponId(instance: Instance): string?
	local cursor: Instance? = instance
	while cursor do
		local value = cursor:GetAttribute("WeaponId")
		if typeof(value) == "string" and value ~= "" then
			return value
		end
		cursor = cursor.Parent
	end

	return nil
end

local function isEquipTarget(instance: Instance?): boolean
	if not instance then
		return false
	end

	local player = Players.LocalPlayer
	if player.Character and instance:IsDescendantOf(player.Character) then
		return true
	end

	local cursor: Instance? = instance
	while cursor do
		if cursor:GetAttribute("WeaponEquipZone") == true then
			return true
		end
		cursor = cursor.Parent
	end

	return false
end

local function moveDraggedInstance(instance: Instance, worldPosition: Vector3, orientation: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(CFrame.new(worldPosition) * orientation.Rotation)
		return
	end

	if instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(worldPosition) * orientation.Rotation
	end
end

function DragController.new(dragActionRemote: RemoteEvent)
	local self = setmetatable({}, DragController)
	self.dragActionRemote = dragActionRemote
	self.dragStartedEvent = Instance.new("BindableEvent")
	self.dragUpdatedEvent = Instance.new("BindableEvent")
	self.dragEndedEvent = Instance.new("BindableEvent")
	self.connections = {}
	self.isEnabled = false
	self.activeDrag = nil
	self.lastRemoteUpdateAt = 0
	return self
end

function DragController:getDragStartedEvent(): BindableEvent
	return self.dragStartedEvent
end

function DragController:getDragUpdatedEvent(): BindableEvent
	return self.dragUpdatedEvent
end

function DragController:getDragEndedEvent(): BindableEvent
	return self.dragEndedEvent
end

function DragController:beginDrag(candidate: Instance)
	local dragTarget = findDraggableTarget(candidate)
	if not dragTarget then
		return
	end

	local weaponId = getWeaponId(dragTarget)
	if not weaponId then
		return
	end

	local camera = getCamera()
	local origin, direction = getMouseRay(1000)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { Players.LocalPlayer.Character }
	local result = workspace:Raycast(origin, direction, raycastParams)
	local hitPosition = if result then result.Position else origin + direction
	local dragDistance = math.max(4, (hitPosition - camera.CFrame.Position).Magnitude)

	local orientation: CFrame
	if dragTarget:IsA("Model") then
		orientation = dragTarget:GetPivot()
	elseif dragTarget:IsA("BasePart") then
		orientation = dragTarget.CFrame
	else
		return
	end

	self.activeDrag = {
		target = dragTarget,
		weaponId = weaponId,
		distance = dragDistance,
		orientation = orientation,
	}

	self.dragActionRemote:FireServer("begin", {
		weaponId = weaponId,
	})
	self.dragStartedEvent:Fire({
		weaponId = weaponId,
		target = dragTarget,
	})
end

function DragController:updateDrag()
	if not self.activeDrag then
		return
	end

	local drag = self.activeDrag
	local camera = getCamera()
	local origin, direction = getMouseRay(1000)
	local worldPosition = origin + direction.Unit * drag.distance

	moveDraggedInstance(drag.target, worldPosition, drag.orientation)

	local payload: DragPayload = {
		weaponId = drag.weaponId,
		worldPosition = worldPosition,
		target = drag.target,
	}
	self.dragUpdatedEvent:Fire(payload)

	local now = os.clock()
	if now - self.lastRemoteUpdateAt >= DRAG_UPDATE_INTERVAL then
		self.lastRemoteUpdateAt = now
		self.dragActionRemote:FireServer("update", {
			weaponId = drag.weaponId,
			worldPosition = worldPosition,
		})
	end

	local distanceToCamera = (worldPosition - camera.CFrame.Position).Magnitude
	if distanceToCamera < 3 then
		self.activeDrag.distance = DEFAULT_DRAG_DISTANCE
	end
end

function DragController:endDrag()
	if not self.activeDrag then
		return
	end

	local drag = self.activeDrag
	self.activeDrag = nil

	local origin, direction = getMouseRay(1000)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { drag.target }
	local result = workspace:Raycast(origin, direction, params)
	local target = if result then result.Instance else nil
	local shouldEquip = isEquipTarget(target)

	local payload: DragPayload = {
		weaponId = drag.weaponId,
		shouldEquip = shouldEquip,
		target = target,
	}
	self.dragActionRemote:FireServer("end", {
		weaponId = drag.weaponId,
		shouldEquip = shouldEquip,
	})
	self.dragEndedEvent:Fire(payload)
end

function DragController:start()
	if self.isEnabled then
		return
	end
	self.isEnabled = true

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		local origin, direction = getMouseRay(1000)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { Players.LocalPlayer.Character }
		local result = workspace:Raycast(origin, direction, params)
		if result then
			self:beginDrag(result.Instance)
		end
	end))

	table.insert(self.connections, UserInputService.InputEnded:Connect(function(input, _gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:endDrag()
		end
	end))

	table.insert(self.connections, RunService.RenderStepped:Connect(function()
		self:updateDrag()
	end))
end

function DragController:stop()
	if not self.isEnabled then
		return
	end
	self.isEnabled = false
	self.activeDrag = nil
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
end

function DragController:destroy()
	self:stop()
	self.dragStartedEvent:Destroy()
	self.dragUpdatedEvent:Destroy()
	self.dragEndedEvent:Destroy()
end

return DragController
