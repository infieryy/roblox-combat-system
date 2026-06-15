local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local DragConfig = require(Shared:WaitForChild("Drag"):WaitForChild("DragConfig"))

local localPlayer = Players.LocalPlayer

local DragController = {}
DragController.__index = DragController

function DragController.new(remotesFolder)
	local self = setmetatable({}, DragController)
	self.remotes = remotesFolder
	self.isDragging = false
	self.dragTarget = nil
	self.rawDragDelta = Vector2.zero
	self.smoothedDragDelta = Vector2.zero
	self.dragUpdateAccumulator = 0
	self.connections = {}

	self:_bindInput()
	self:_bindRenderStep()
	return self
end

function DragController:_isDraggable(hitInstance)
	if not hitInstance or not hitInstance:IsA("BasePart") then
		return false
	end

	return hitInstance:GetAttribute("Draggable") == true
		or CollectionService:HasTag(hitInstance, DragConfig.draggableTag)
end

function DragController:_raycastFromMouse()
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local character = localPlayer.Character
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = character and { character } or {}

	return Workspace:Raycast(ray.Origin, ray.Direction * DragConfig.maxHoldDistance, raycastParams)
end

function DragController:_beginDrag()
	local raycastResult = self:_raycastFromMouse()
	if not raycastResult or not self:_isDraggable(raycastResult.Instance) then
		return
	end

	self.isDragging = true
	self.dragTarget = raycastResult.Instance
	self.remotes.BeginDrag:FireServer(raycastResult.Instance, raycastResult.Position)
end

function DragController:_endDrag()
	if not self.isDragging then
		return
	end

	self.isDragging = false
	self.dragTarget = nil
	self.remotes.EndDrag:FireServer()
end

function DragController:_bindInput()
	self.connections.inputBegan = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_beginDrag()
		end
	end)

	self.connections.inputChanged = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		self.rawDragDelta = input.Delta
	end)

	self.connections.inputEnded = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_endDrag()
		end
	end)
end

function DragController:_bindRenderStep()
	self.connections.renderStepped = RunService.RenderStepped:Connect(function(deltaTime)
		self.smoothedDragDelta = self.smoothedDragDelta:Lerp(self.rawDragDelta, math.clamp(deltaTime * 18, 0, 1))
		self.rawDragDelta = Vector2.zero

		if not self.isDragging then
			return
		end

		self.dragUpdateAccumulator += deltaTime
		if self.dragUpdateAccumulator < DragConfig.updateRate then
			return
		end
		self.dragUpdateAccumulator = 0

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		local mouseLocation = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
		local desiredPosition = ray.Origin + ray.Direction.Unit * DragConfig.holdDistance
		self.remotes.UpdateDrag:FireServer(desiredPosition)
	end)
end

function DragController:IsDragging()
	return self.isDragging
end

function DragController:GetSmoothedDelta()
	return self.smoothedDragDelta
end

function DragController:Destroy()
	self:_endDrag()
	for _, connection in pairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}
end

return DragController
