--!strict
-- Module: DragController
-- Client-side drag steering (ported from consensus, mouse-driven, no rotation).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local GeometryUtil = require(ReplicatedStorage.Shared.GeometryUtil)

type Remotes = typeof(require(script.Parent.RemotesClient).waitForRemotes())

local DragController = {}

local remotes: Remotes? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	grabOrientation: CFrame,
}

local hold: Hold? = nil
local dragging = false
local rotating = false
local frozenCameraCFrame: CFrame? = nil

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
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
	if rotating and frozenCameraCFrame and Config.Drag.enableInspect then
		cam.CFrame = frozenCameraCFrame
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = Config.Drag.rotateSensitivity
			local deltaRotation = CFrame.Angles(0, -delta.X * sensitivity, 0)
				* CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			current.grabOrientation = deltaRotation * current.grabOrientation
		end
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition
	current.alignOrientation.CFrame = current.grabOrientation
end

local function beginHold(
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation
)
	local cam = getCamera()
	local grabOrientation = alignOrientation.CFrame
	if cam then
		grabOrientation = primary.CFrame.Rotation
		alignOrientation.CFrame = grabOrientation
	end

	hold = {
		object = object,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = GeometryUtil.computeHoldDistance(object),
		grabOrientation = grabOrientation,
	}
	dragging = true
end

local function endHold()
	hold = nil
	dragging = false
	rotating = false
	frozenCameraCFrame = nil
end

function DragController.isDragging(): boolean
	return dragging
end

function DragController.getHeldObject(): Instance?
	return if hold then hold.object else nil
end

function DragController.beginDrag(prop: Instance)
	if dragging or not remotes then
		return
	end
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	if not remotes then
		return
	end
	if dragging then
		remotes.DragEndRequest:FireServer()
	end
end

function DragController.start(remoteTable: Remotes)
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

	if Config.Drag.enableInspect then
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed or not hold then
				return
			end
			if input.KeyCode == Config.Input.inspectKey or input.KeyCode == Config.Input.gamepadInspectKey then
				rotating = true
				frozenCameraCFrame = getCamera() and getCamera().CFrame or nil
				local cam = getCamera()
				if cam then
					cam.CameraType = Enum.CameraType.Scriptable
				end
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			end
		end)

		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.KeyCode == Config.Input.inspectKey or input.KeyCode == Config.Input.gamepadInspectKey then
				rotating = false
				frozenCameraCFrame = nil
				local cam = getCamera()
				if cam then
					cam.CameraType = Enum.CameraType.Custom
				end
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end)
	end

	RunService:BindToRenderStep("DragControllerUpdate", Enum.RenderPriority.Camera.Value + 2, function()
		local cam = getCamera()
		if cam and hold then
			steerHold(cam)
		end
	end)
end

function DragController.onCharacterChanged()
	if hold then
		endHold()
	end
end

return DragController
