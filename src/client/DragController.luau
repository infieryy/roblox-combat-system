--!strict
-- Module: client/DragController.luau
-- Ported steering from consensus FirstPersonPickupClient (mouse-driven, no rotation).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local GeometryUtil = require(ReplicatedStorage.Shared.GeometryUtil)

local DragController = {}

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	fixedOrientation: CFrame,
	rotationOffset: CFrame,
}

local remotes: {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
}? = nil

local player = Players.LocalPlayer
local hold: Hold? = nil
local dragging = false
local rotating = false
local frozenCameraCFrame: CFrame? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
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
			local deltaRotation = CFrame.Angles(0, -delta.X * sensitivity, 0) * CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			current.rotationOffset = deltaRotation * current.rotationOffset
		end
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition

	if Config.Drag.enableInspect then
		current.alignOrientation.CFrame = camCF.Rotation * current.rotationOffset
	else
		current.alignOrientation.CFrame = current.fixedOrientation
	end
end

local function beginHold(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	local cam = getCamera()
	local fixedOrientation = alignOrientation.CFrame

	hold = {
		object = object,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = GeometryUtil.computeHoldDistance(object),
		fixedOrientation = fixedOrientation,
		rotationOffset = CFrame.identity,
	}
	dragging = true
end

local function endHold()
	hold = nil
	dragging = false
	rotating = false
	frozenCameraCFrame = nil
end

function DragController.beginDrag(prop: Instance)
	if dragging or hold then
		return
	end
	if remotes then
		remotes.DragStartRequest:FireServer(prop)
	end
end

function DragController.endDrag()
	if not dragging and not hold then
		return
	end
	if remotes then
		remotes.DragEndRequest:FireServer()
	end
end

function DragController.isDragging(): boolean
	return dragging or hold ~= nil
end

function DragController.getHeldObject(): Instance?
	return if hold then hold.object else nil
end

function DragController.onRenderStep()
	local cam = getCamera()
	if not cam or not hold then
		return
	end
	steerHold(cam)

	local head = player.Character and player.Character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local distance = (hold.primary.Position - head.Position).Magnitude
		if distance > Config.Drag.maxHoldDistance + GeometryUtil.getBoundingRadius(hold.object) + 2 then
			DragController.endDrag()
		end
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

function DragController.onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if dragging or hold then
			DragController.endDrag()
		end
	end
end

function DragController.configure(remoteTable: typeof(remotes))
	remotes = remoteTable

	if not remotes then
		return
	end

	remotes.DragGranted.OnClientEvent:Connect(function(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
		if object and primary and alignPosition and alignOrientation then
			beginHold(object, primary, alignPosition, alignOrientation)
		end
	end)

	remotes.DragEnded.OnClientEvent:Connect(function()
		endHold()
	end)
end

function DragController.start()
	RunService:BindToRenderStep("ItemSystemDragUpdate", Enum.RenderPriority.Camera.Value + 1, function()
		DragController.onRenderStep()
	end)
end

function DragController.onHoldStateChanged(kind: string)
	if kind == "None" or kind == "Weapon" then
		endHold()
	end
end

function DragController.onCharacterAdded()
	endHold()
end

return DragController
