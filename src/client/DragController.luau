--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

type ActiveDrag = {
	prop: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	initialOrientation: CFrame,
	inspectOffset: CFrame,
}

local DragController = {}

local remotes: any = nil
local active: ActiveDrag? = nil
local draggingRequested = false
local inspecting = false

local function getCamera(): Camera?
	return workspace.CurrentCamera
end

local function clearActive()
	active = nil
	draggingRequested = false
	inspecting = false
end

local function onDragGranted(prop: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation, boundingRadius: number?)
	local radius = boundingRadius or 0
	active = {
		prop = prop,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = math.clamp(Config.Drag.holdDistance + radius * 0.5, Config.Drag.minHoldDistance, Config.Drag.maxHoldDistance + radius),
		initialOrientation = primary.CFrame.Rotation,
		inspectOffset = CFrame.identity,
	}
	draggingRequested = true
end

local function onHoldStateChanged(state: any)
	if typeof(state) ~= "table" then
		return
	end
	if state.kind ~= "Prop" and active then
		clearActive()
	end
end

local function onInputChanged(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel and active then
		active.holdDistance = math.clamp(
			active.holdDistance - input.Position.Z * Config.Drag.scrollStep,
			Config.Drag.minHoldDistance,
			Config.Drag.maxHoldDistance
		)
	end
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not active or not Config.Drag.enableInspect then
		return
	end
	if input.KeyCode == Config.Input.reloadKey then
		inspecting = true
	end
end

local function onInputEnded(input: InputObject)
	if Config.Drag.enableInspect and input.KeyCode == Config.Input.reloadKey then
		inspecting = false
	end
end

local function updateInspect()
	if not active or not Config.Drag.enableInspect or not inspecting then
		return
	end
	local delta = UserInputService:GetMouseDelta()
	if delta.Magnitude <= 0 then
		return
	end
	local sensitivity = Config.Drag.rotateSensitivity
	local deltaRot = CFrame.Angles(-delta.Y * sensitivity, -delta.X * sensitivity, 0)
	active.inspectOffset = deltaRot * active.inspectOffset
end

local function updateHeld()
	if not active then
		return
	end
	if not active.alignPosition.Parent or not active.alignOrientation.Parent then
		clearActive()
		return
	end

	local camera = getCamera()
	if not camera then
		return
	end

	updateInspect()
	local goalCFrame = camera.CFrame * CFrame.new(0, 0, -active.holdDistance)
	active.alignPosition.Position = goalCFrame.Position
	if Config.Drag.enableInspect then
		active.alignOrientation.CFrame = active.initialOrientation * active.inspectOffset
	else
		active.alignOrientation.CFrame = active.initialOrientation
	end
end

function DragController.beginDrag(prop: Instance)
	if active then
		return
	end
	draggingRequested = true
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	if not active and not draggingRequested then
		return
	end
	remotes.DragEndRequest:FireServer()
	clearActive()
end

function DragController.isDragging(): boolean
	return active ~= nil or draggingRequested
end

function DragController.start(remoteMap: any)
	remotes = remoteMap
	remotes.DragGranted.OnClientEvent:Connect(onDragGranted)
	remotes.DragEnded.OnClientEvent:Connect(function()
		clearActive()
	end)
	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)

	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	RunService.RenderStepped:Connect(updateHeld)
end

return DragController
