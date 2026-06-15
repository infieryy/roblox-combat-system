--!strict
-- Module: client/DragController
-- Ported constraint steering from the consensus client. The server builds the
-- AlignPosition/AlignOrientation rig and hands us the refs; we steer the
-- position goal locally every frame (zero perceived lag). Bridge changes:
--   * Mouse-grab, not E: beginDrag is called by InteractionController on
--     mouse-down over a draggable prop; releasing the mouse drops (fling is
--     emergent from retained velocity).
--   * No rotation (decision #2): we never drive alignOrientation; the server
--     fixed it at grab time. Inspect-rotate is kept but gated behind
--     Config.Drag.enableInspect.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

type Context = { [string]: any }

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	rotationOffset: CFrame,
}

local DragCfg = Config.Drag

local DragController = {}

local ctx: Context = nil :: any
local player = Players.LocalPlayer

local hold: Hold? = nil
local pendingObject: Instance? = nil -- requested, awaiting DragGranted
local rotating = false
local frozenCameraCFrame: CFrame? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function computeHoldDistance(target: Instance): number
	local distance = DragCfg.holdDistanceBase + GeometryUtil.getLargestAxis(target) * DragCfg.holdDistancePadding
	return math.clamp(distance, DragCfg.holdDistanceMin, DragCfg.holdDistanceMax)
end

----------------------------------------------------------------------
-- Public state (read by InteractionController for the raycast filter).
----------------------------------------------------------------------

function DragController.isDragging(): boolean
	return hold ~= nil or pendingObject ~= nil
end

function DragController.getObject(): Instance?
	if hold then
		return hold.object
	end
	return pendingObject
end

----------------------------------------------------------------------
-- Inspect (gated off by default).
----------------------------------------------------------------------

local function startInspect()
	if not DragCfg.enableInspect or rotating or not hold then
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

----------------------------------------------------------------------
-- Begin / end.
----------------------------------------------------------------------

function DragController.beginDrag(object: Instance)
	if DragController.isDragging() then
		return
	end
	pendingObject = object
	ctx.remotes.DragStartRequest:FireServer(object)
end

function DragController.endDrag()
	if not DragController.isDragging() then
		return
	end
	if rotating then
		stopInspect()
	end
	ctx.remotes.DragEndRequest:FireServer()
	-- Clear local steering immediately; the server confirms with DragEnded.
	hold = nil
	pendingObject = nil
end

local function clearLocal()
	if rotating then
		stopInspect()
	end
	hold = nil
	pendingObject = nil
end

----------------------------------------------------------------------
-- Per-frame steering.
----------------------------------------------------------------------

local function steer()
	local current = hold
	if not current then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end
	-- The object vanished or the server tore the rig down.
	if not current.primary.Parent or not current.alignPosition.Parent then
		clearLocal()
		return
	end

	local camCF = cam.CFrame
	if DragCfg.enableInspect and rotating and frozenCameraCFrame then
		cam.CFrame = frozenCameraCFrame
		camCF = frozenCameraCFrame
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local s = DragCfg.rotateSensitivity
			local deltaRotation = CFrame.Angles(0, -delta.X * s, 0) * CFrame.Angles(-delta.Y * s, 0, 0)
			current.rotationOffset = deltaRotation * current.rotationOffset
		end
		current.alignOrientation.CFrame = camCF.Rotation * current.rotationOffset
	end

	-- Position goal: a point holdDistance in front of the camera. (Orientation
	-- is left to the server-fixed grab value when inspect is off.)
	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition

	-- Client-side leash mirror: bail if the prop drifts past the server radius.
	local head = cam.CFrame.Position
	if (current.primary.Position - head).Magnitude > DragCfg.maxHoldDistance + 2 then
		DragController.endDrag()
	end
end

----------------------------------------------------------------------
-- Net handlers.
----------------------------------------------------------------------

local function onDragGranted(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	if not (object and primary and alignPosition and alignOrientation) then
		return
	end
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
	}
	pendingObject = nil
end

function DragController.start(context: Context)
	ctx = context

	ctx.remotes.DragGranted.OnClientEvent:Connect(onDragGranted)
	ctx.remotes.DragEnded.OnClientEvent:Connect(function()
		clearLocal()
	end)
	ctx.remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind ~= "Prop" then
			clearLocal()
		end
	end)

	-- Release the mouse to drop.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and DragController.isDragging() then
			DragController.endDrag()
		end
	end)

	-- Scroll adjusts hold distance; R holds to inspect (gated).
	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		local current = hold
		if not current then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			current.holdDistance = math.clamp(
				current.holdDistance - input.Position.Z * DragCfg.scrollStep,
				DragCfg.holdDistanceMin,
				DragCfg.holdDistanceMax
			)
		end
	end)

	if DragCfg.enableInspect then
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if not gameProcessed and input.KeyCode == Config.Input.reloadKey and hold then
				startInspect()
			end
		end)
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.KeyCode == Config.Input.reloadKey then
				stopInspect()
			end
		end)
	end

	player.CharacterAdded:Connect(function()
		clearLocal()
	end)

	-- Steer just after the camera so we read the freshest CFrame.
	RunService:BindToRenderStep("DragControllerSteer", Enum.RenderPriority.Camera.Value + 2, steer)
end

return DragController
