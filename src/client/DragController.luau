--!strict
-- Module: DragController
-- Ported client-side constraint steering (mouse-driven grab, no rotation by default).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local RemotesClient = require(script.Parent.RemotesClient)

type RemotesClientTable = RemotesClient.RemotesClientTable

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	rotationOffset: CFrame,
	grabOrientation: CFrame,
}

local DragController = {}

local remotes: RemotesClientTable? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local hold: Hold? = nil
local dragging = false
local rotating = false
local frozenCameraCFrame: CFrame? = nil
local holdKind: string = "None"

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function computeHoldDistance(target: Instance): number
	local distance = Config.Drag.holdDistanceBase + GeometryUtil.getLargestAxis(target) * Config.Drag.holdDistancePadding
	return math.clamp(distance, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

local function startInspect()
	if not Config.Drag.enableInspect or rotating or not hold then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end
	rotating = true
	frozenCameraCFrame = cam.CFrame
	cam.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
end

local function stopInspect()
	if not rotating then
		return
	end
	rotating = false
	frozenCameraCFrame = nil
	local cam = getCamera()
	if cam then
		cam.CameraType = Enum.CameraType.Custom
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

local function steerHold(cam: Camera)
	local current = hold
	if not current then
		return
	end
	if not current.primary.Parent or not current.alignPosition.Parent or not current.alignOrientation.Parent then
		return
	end

	local camCF = (rotating and frozenCameraCFrame) or cam.CFrame
	if rotating and frozenCameraCFrame then
		cam.CFrame = frozenCameraCFrame
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = Config.Drag.rotateSensitivity
			local deltaRotation = CFrame.Angles(0, -delta.X * sensitivity, 0)
				* CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			current.rotationOffset = deltaRotation * current.rotationOffset
		end
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition

	if Config.Drag.enableInspect then
		local goalRotation = camCF.Rotation * current.rotationOffset
		current.alignOrientation.CFrame = goalRotation
	else
		current.alignOrientation.CFrame = current.grabOrientation
	end
end

local function beginHold(
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation
)
	local cam = getCamera()
	local rotationOffset = CFrame.identity
	if cam then
		rotationOffset = cam.CFrame.Rotation:Inverse() * primary.CFrame.Rotation
	end

	hold = {
		object = object,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = computeHoldDistance(object),
		rotationOffset = rotationOffset,
		grabOrientation = alignOrientation.CFrame,
	}
	dragging = true
end

local function endHold()
	hold = nil
	dragging = false
	if rotating then
		stopInspect()
	end
end

function DragController.isDragging(): boolean
	return dragging
end

function DragController.beginDrag(prop: Instance)
	if holdKind ~= "None" or dragging or not remotes then
		return
	end
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	if not remotes then
		return
	end
	if dragging or hold then
		remotes.DragEndRequest:FireServer()
	end
end

function DragController.getHeldObject(): Instance?
	return if hold then hold.object else nil
end

function DragController.onHoldStateChanged(kind: string)
	holdKind = kind
	if kind ~= "Prop" then
		endHold()
	end
end

local function onRenderStep()
	local cam = getCamera()
	if not cam then
		return
	end
	if hold then
		steerHold(cam)

		local head = player.Character and player.Character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local maxDistance = Config.Drag.maxHoldDistance + GeometryUtil.getBoundingRadius(hold.object)
			if (hold.primary.Position - head.Position).Magnitude > maxDistance then
				DragController.endDrag()
			end
		end
	else
		return
	end
end

function DragController.start(remotesTable: RemotesClientTable)
	remotes = remotesTable

	remotesTable.DragGranted.OnClientEvent:Connect(function(
		object: Instance,
		primary: BasePart,
		alignPosition: AlignPosition,
		alignOrientation: AlignOrientation
	)
		if not (object and primary and alignPosition and alignOrientation) then
			return
		end
		beginHold(object, primary, alignPosition, alignOrientation)
	end)

	remotesTable.DragEnded.OnClientEvent:Connect(function()
		endHold()
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dragging or hold then
				DragController.endDrag()
			end
		end
		if Config.Drag.enableInspect then
			local inspectKey = Config.Input.inspectKey
			local gamepadInspect = Config.Input.gamepadInspectKey
			if input.KeyCode == inspectKey or input.KeyCode == gamepadInspect then
				stopInspect()
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if Config.Drag.enableInspect and hold then
			local inspectKey = Config.Input.inspectKey
			local gamepadInspect = Config.Input.gamepadInspectKey
			if input.KeyCode == inspectKey or input.KeyCode == gamepadInspect then
				startInspect()
			end
		end
		if input.KeyCode == Config.Input.dropKey and hold then
			DragController.endDrag()
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not hold then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			hold.holdDistance = math.clamp(
				hold.holdDistance - input.Position.Z * Config.Drag.scrollStep,
				Config.Drag.holdDistanceMin,
				Config.Drag.holdDistanceMax
			)
		end
	end)

	RunService:BindToRenderStep("DragControllerUpdate", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

return DragController
