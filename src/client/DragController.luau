--!strict
-- Module: DragController
-- Client-side prop drag controller.
-- Ported from the consensus FirstPersonPickupClient with the following changes:
--   * Input changed from E-key pickup to mouse-hold (beginDrag called by InteractionController).
--   * Rotation is LOCKED at grab time (decision #2: props do not rotate while held).
--     Inspect mode code path is present but gated by Config.Drag.enableInspect (false in v1).
--   * Remote names updated to DragStartRequest / DragGranted / DragEndRequest / DragEnded.
--   * DragController is now a module with a public API used by InteractionController.
--
-- Physics principle (unchanged from consensus):
--   The server transfers network ownership of the held prop to us. We steer
--   the AlignPosition / AlignOrientation goals locally every RenderStep. The
--   simulation runs on our machine (zero perceived lag) and replicates outward.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local Remotes = require(script.Parent:WaitForChild("RemotesClient"))

local DragController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

type Hold = {
	object:           Instance,
	primary:          BasePart,
	alignPosition:    AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance:     number,
	-- Grab-time orientation expressed relative to the camera so the object
	-- keeps its orientation as the view rotates (consistent with consensus behaviour).
	rotationOffset:   CFrame,
	-- Inspect mode (only active if Config.Drag.enableInspect == true)
	frozenCameraCFrame: CFrame?,
}

local hold: Hold? = nil
local character: Model? = player.Character
local rotating = false

-- -------------------------------------------------------------------------
-- Geometry (delegated to GeometryUtil)
-- -------------------------------------------------------------------------

local function refreshCamera()
	camera = Workspace.CurrentCamera
end

-- -------------------------------------------------------------------------
-- Inspect mode (gated by Config.Drag.enableInspect — off in v1)
-- -------------------------------------------------------------------------

local function startInspect()
	if not Config.Drag.enableInspect or rotating or not hold then return end
	rotating = true
	hold.frozenCameraCFrame = camera.CFrame
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
end

local function stopInspect()
	if not rotating then return end
	rotating = false
	if hold then hold.frozenCameraCFrame = nil end
	camera.CameraType = Enum.CameraType.Custom
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

-- -------------------------------------------------------------------------
-- Constraint steering (RenderStepped)
-- -------------------------------------------------------------------------

local function steerHold()
	local current = hold
	if not current then return end

	-- If the rig was destroyed server-side (leash, death, etc.) stop steering.
	if not current.primary.Parent
		or not current.alignPosition.Parent
		or not current.alignOrientation.Parent
	then
		return
	end

	local camCF = camera.CFrame

	-- Inspect-rotate path (v1: gated off; code path preserved for v2).
	if rotating and Config.Drag.enableInspect and current.frozenCameraCFrame then
		camera.CFrame = current.frozenCameraCFrame
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = 0.0125
			local deltaRot = CFrame.Angles(0, -delta.X * sensitivity, 0)
				* CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			current.rotationOffset = deltaRot * current.rotationOffset
		end
		camCF = current.frozenCameraCFrame
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position

	-- Decision #2: orientation is locked at grab time; rotationOffset is NOT updated
	-- each frame (no per-frame rotation steering). AlignOrientation goal is held constant.
	local goalRotation = camCF.Rotation * current.rotationOffset

	current.alignPosition.Position = goalPosition
	current.alignOrientation.CFrame = goalRotation
end

-- -------------------------------------------------------------------------
-- Hold lifecycle
-- -------------------------------------------------------------------------

local function beginHold(
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation
)
	local rotationOffset = CFrame.identity
	rotationOffset = camera.CFrame.Rotation:Inverse() * primary.CFrame.Rotation

	hold = {
		object           = object,
		primary          = primary,
		alignPosition    = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance     = GeometryUtil.computeHoldDistance(object),
		rotationOffset   = rotationOffset,
		frozenCameraCFrame = nil,
	}
end

local function endHold()
	if rotating then stopInspect() end
	hold = nil
end

-- -------------------------------------------------------------------------
-- Scroll distance adjustment
-- -------------------------------------------------------------------------

UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end
	local current = hold
	if not current then return end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		current.holdDistance = math.clamp(
			current.holdDistance - input.Position.Z * Config.Drag.scrollStep,
			Config.Drag.holdDistanceMin,
			Config.Drag.holdDistanceMax
		)
	end
end)

-- Inspect toggle (R key) — only functional when enableInspect == true
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.R and Config.Drag.enableInspect and hold then
		startInspect()
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.KeyCode == Enum.KeyCode.R then
		stopInspect()
	end
end)

-- -------------------------------------------------------------------------
-- Network handlers
-- -------------------------------------------------------------------------

Remotes.DragGranted.OnClientEvent:Connect(function(
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation
)
	if not (object and primary and alignPosition and alignOrientation) then return end
	beginHold(object, primary, alignPosition, alignOrientation)
end)

Remotes.DragEnded.OnClientEvent:Connect(function()
	endHold()
end)

-- React to authoritative server hold-state override
-- (e.g. server equips a weapon while a drag is in progress).
Remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
	if kind == "None" or kind == "Weapon" then
		endHold()
	end
end)

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- Called by InteractionController when the player mouse-downs on a draggable prop.
function DragController.beginDrag(prop: Instance)
	if hold then return end   -- already dragging
	Remotes.DragStartRequest:FireServer(prop)
end

-- Called by InteractionController when the player mouse-ups (or from internal sources).
function DragController.endDrag()
	if not hold then return end
	endHold()
	Remotes.DragEndRequest:FireServer()
end

function DragController.isDragging(): boolean
	return hold ~= nil
end

-- -------------------------------------------------------------------------
-- RenderStep loop
-- -------------------------------------------------------------------------

-- start() is called from init.client.luau.
function DragController.start()
	-- Character tracking for raycast filter updates.
	player.CharacterAdded:Connect(function(char)
		character = char
		if hold then endHold() end
	end)
	if player.Character then
		character = player.Character
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(refreshCamera)

	RunService:BindToRenderStep(
		"DragControllerUpdate",
		Enum.RenderPriority.Camera.Value + 1,
		steerHold
	)
end

return DragController
