--!strict
-- Module: DragController
-- Client-side steering of server-built AlignPosition/AlignOrientation rigs.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local RemotesClient = require(script.Parent.RemotesClient)

local DragController = {}

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	rotationOffset: CFrame,
	grabOrientation: CFrame,
}

local player = Players.LocalPlayer
local remotes: RemotesClient.RemotesClientTable? = nil
local hold: Hold? = nil
local dragging = false
local rotating = false
local frozenCameraCFrame: CFrame? = nil
local camera = Workspace.CurrentCamera

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function isDragging(): boolean
	return hold ~= nil
end

function DragController.isDragging(): boolean
	return isDragging()
end

local function steerHold(cam: Camera)
	local current = hold
	if not current then
		return
	end

	if not current.primary.Parent or not current.alignPosition.Parent or not current.alignOrientation.Parent then
		return
	end

	local camCF = cam.CFrame
	if Config.Drag.enableInspect and rotating and frozenCameraCFrame then
		camCF = frozenCameraCFrame
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
		current.alignOrientation.CFrame = camCF.Rotation * current.rotationOffset
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
		holdDistance = GeometryUtil.computeHoldDistance(object),
		rotationOffset = rotationOffset,
		grabOrientation = primary.CFrame.Rotation,
	}
	dragging = true
end

local function endHold()
	hold = nil
	dragging = false
	rotating = false
	frozenCameraCFrame = nil
	local cam = getCamera()
	if cam and Config.Drag.enableInspect then
		cam.CameraType = Enum.CameraType.Custom
	end
	if Config.Drag.enableInspect then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

function DragController.beginDrag(prop: Instance)
	if hold or not remotes then
		return
	end
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	if not remotes then
		return
	end
	remotes.DragEndRequest:FireServer()
	endHold()
end

function DragController.getHeldObject(): Instance?
	return if hold then hold.object else nil
end

function DragController.onRenderStep()
	local cam = getCamera()
	if not cam then
		return
	end
	if hold then
		steerHold(cam)
	end
end

function DragController.onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not hold then
		return
	end

	if input.KeyCode == Config.Input.dropKey then
		DragController.endDrag()
	elseif Config.Drag.enableInspect and (
		input.KeyCode == Config.Input.rotateKey or input.KeyCode == Config.Input.gamepadRotateKey
	) then
		local cam = getCamera()
		if cam then
			rotating = true
			frozenCameraCFrame = cam.CFrame
			cam.CameraType = Enum.CameraType.Scriptable
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end
end

function DragController.onInputEnded(input: InputObject)
	if Config.Drag.enableInspect and (
		input.KeyCode == Config.Input.rotateKey or input.KeyCode == Config.Input.gamepadRotateKey
	) then
		rotating = false
		frozenCameraCFrame = nil
		local cam = getCamera()
		if cam then
			cam.CameraType = Enum.CameraType.Custom
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

function DragController.onInputChanged(input: InputObject, gameProcessed: boolean)
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
end

function DragController.start(remoteTable: RemotesClient.RemotesClientTable)
	remotes = remoteTable

	remoteTable.DragGranted.OnClientEvent:Connect(function(
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

	remoteTable.DragEnded.OnClientEvent:Connect(function()
		endHold()
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "None" or kind == "Weapon" then
			endHold()
		end
	end)
end

return DragController
