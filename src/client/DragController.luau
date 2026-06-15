--!strict
-- Module: DragController  (client-side)
-- Steers the server-built AlignPosition/AlignOrientation rig every frame.
-- Ported from consensus FirstPersonPickupClient.steerHold() with bridging changes:
--   • Trigger is LMB (mouse-hold), not the E key.
--   • beginDrag/endDrag called by InteractionController, not input-bound here.
--   • AlignOrientation goal is fixed at grab time (decision #2, no per-frame rotation).
--   • inspect-rotate code path present but gated by Config.Drag.enableInspect.
--   • Scroll adjusts holdDistance (ported).
--   • Exposes smoothedMouseDelta for ViewmodelController sway.
-- Blueprint §11.3.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))

local player = Players.LocalPlayer

-- -------------------------------------------------------------------------
-- DragController class
-- -------------------------------------------------------------------------

local DragController = {}
DragController.__index = DragController

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	grabOrientation: CFrame, -- fixed grab-time orientation goal (decision #2)
}

type RemotesInterface = {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
}

function DragController.new(remotes: RemotesInterface)
	local self = setmetatable({}, DragController)
	self.remotes = remotes
	self._hold = nil :: Hold?
	self._dragging = false
	self._rawMouseDelta = Vector2.zero
	self._smoothedMouseDelta = Vector2.zero
	self._connections = {}

	-- Expose for InteractionController's raycast filter.
	self.heldObject = nil :: Instance?

	self:_bindRemotes()
	return self
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function DragController:isDragging(): boolean
	return self._dragging
end

-- Smoothed mouse delta — consumed by ViewmodelController for sway.
function DragController:getSmoothedDelta(): Vector2
	return self._smoothedMouseDelta
end

function DragController:beginDrag(prop: Instance)
	if self._dragging then return end
	self._dragging = true
	self.heldObject = prop
	self.remotes.DragStartRequest:FireServer(prop)
end

function DragController:endDrag()
	if not self._dragging then return end
	self._dragging = false
	self.heldObject = nil
	self._hold = nil
	self.remotes.DragEndRequest:FireServer()
end

-- -------------------------------------------------------------------------
-- Rig steering
-- -------------------------------------------------------------------------

local function steerHold(hold: Hold)
	-- Safety: rig may have been destroyed by server.
	if not hold.primary.Parent
		or not hold.alignPosition.Parent
		or not hold.alignOrientation.Parent
	then
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then return end

	local goalPosition = (cam.CFrame * CFrame.new(0, 0, -hold.holdDistance)).Position
	hold.alignPosition.Position = goalPosition

	-- Decision #2: orientation goal stays fixed at grab time.
	-- (Inspect-rotate path kept but gated off in v1.)
	if Config.Drag.enableInspect then
		-- TODO(v2): drive alignOrientation from camera delta for inspect mode.
	else
		hold.alignOrientation.CFrame = hold.grabOrientation
	end
end

-- -------------------------------------------------------------------------
-- Remote listeners
-- -------------------------------------------------------------------------

function DragController:_bindRemotes()
	-- Server grants the rig — begin steering.
	table.insert(self._connections,
		self.remotes.DragGranted.OnClientEvent:Connect(function(
			object: Instance,
			primary: BasePart,
			alignPosition: AlignPosition,
			alignOrientation: AlignOrientation
		)
			if not (object and primary and alignPosition and alignOrientation) then return end

			local cam = Workspace.CurrentCamera
			local grabOrientation = alignOrientation.CFrame -- the server set this to grab-time world rotation

			self._hold = {
				object = object,
				primary = primary,
				alignPosition = alignPosition,
				alignOrientation = alignOrientation,
				holdDistance = GeometryUtil.computeHoldDistance(object),
				grabOrientation = grabOrientation,
			}
			self.heldObject = object
		end)
	)

	-- Server ended the drag (leash, death, etc.).
	table.insert(self._connections,
		self.remotes.DragEnded.OnClientEvent:Connect(function()
			self._hold = nil
			self._dragging = false
			self.heldObject = nil
		end)
	)

	-- Mouse delta tracking (for ViewmodelController sway).
	table.insert(self._connections,
		UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then return end
			if self._hold and input.UserInputType == Enum.UserInputType.MouseWheel then
				self._hold.holdDistance = math.clamp(
					self._hold.holdDistance - input.Position.Z * Config.Drag.scrollStep,
					Config.Drag.holdDistanceMin,
					Config.Drag.holdDistanceMax
				)
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				self._rawMouseDelta = Vector2.new(input.Delta.X, input.Delta.Y)
			end
		end)
	)

	-- Player character respawn → clear local hold state (server also drops).
	table.insert(self._connections,
		player.CharacterAdded:Connect(function()
			self._hold = nil
			self._dragging = false
			self.heldObject = nil
		end)
	)

	-- Per-frame: steer the rig + smooth mouse delta.
	RunService:BindToRenderStep(
		"DragControllerUpdate",
		Enum.RenderPriority.Camera.Value + 2,
		function(dt: number)
			-- Smooth mouse delta (for viewmodel sway).
			self._smoothedMouseDelta = self._smoothedMouseDelta:Lerp(
				self._rawMouseDelta,
				math.clamp(dt * 18, 0, 1)
			)
			self._rawMouseDelta = Vector2.zero

			local h = self._hold
			if h then
				steerHold(h)
			end
		end
	)
end

-- start() is a no-op; the render loop and remotes are wired in new().
-- Provided for interface consistency with the other controllers.
function DragController:start() end

function DragController:destroy()
	self:endDrag()
	RunService:UnbindFromRenderStep("DragControllerUpdate")
	for _, c in self._connections do c:Disconnect() end
	self._connections = {}
end

return DragController
