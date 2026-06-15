--!strict
--[[
	DragController  (client/DragController.luau → StarterPlayerScripts.Client.DragController)
	---------------------------------------------------------------------------------------------
	Ported from the consensus FirstPersonPickupClient — the same AlignPosition steering
	logic, now mouse-driven (mouse-hold-to-drag, release-to-fling, no E).

	Changes from consensus:
	  • Grab is mouse-button-down (not E); release is mouse-button-up → fling.
	  • Called programmatically by InteractionController, not via input polling here.
	  • AlignOrientation goal is held at grab-time orientation — never updated
	    per-frame (decision #2). Inspect-rotate is present but gated off.
	  • Scroll wheel still adjusts holdDistance while dragging.
	  • Reacts to HoldStateChanged("None") from the server for forced releases.
]]

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = require(Shared:WaitForChild("Config"))
local GeometryUtil  = require(Shared:WaitForChild("GeometryUtil"))
local RemotesClient = require(script.Parent:WaitForChild("RemotesClient"))

local LocalPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

type DragState = {
	object:           Instance,
	primary:          BasePart,
	alignPosition:    AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance:     number,
	-- Grab-time orientation relative to the camera; held constant (decision #2).
	grabOrientOffset: CFrame,
}

local dragState: DragState? = nil
-- True when we have sent DragStartRequest but not yet received DragGranted.
local pendingDrag = false

-- Inspect-rotate state (gated by Config.Drag.enableInspect).
local inspecting    = false
local inspectOffset = CFrame.identity -- accumulated rotation while inspecting

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-frame steering
-- ─────────────────────────────────────────────────────────────────────────────

local function steer(camera: Camera)
	local ds = dragState
	if not ds then
		return
	end
	-- Guard: server may have torn down the rig before DragEnded arrives.
	if not ds.primary.Parent
		or not ds.alignPosition.Parent
		or not ds.alignOrientation.Parent
	then
		return
	end

	local camCF = camera.CFrame

	-- Position goal: point directly in front of the camera.
	local goalPosition = (camCF * CFrame.new(0, 0, -ds.holdDistance)).Position
	ds.alignPosition.Position = goalPosition

	-- Orientation goal: held at grab-time orientation (no per-frame rotation).
	-- If inspect is enabled the offset accumulates from mouse delta.
	local goalOrientation: CFrame
	if Config.Drag.enableInspect and inspecting then
		goalOrientation = camCF.Rotation * inspectOffset
	else
		goalOrientation = camCF.Rotation * ds.grabOrientOffset
	end
	ds.alignOrientation.CFrame = goalOrientation
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

local DragController = {}

-- Called by InteractionController when the player mouse-downs over a prop.
function DragController.beginDrag(prop: Instance)
	if pendingDrag or dragState then
		return
	end
	pendingDrag = true
	inspectOffset = CFrame.identity

	local remotes = RemotesClient.get()
	remotes.DragStartRequest:FireServer(prop)
end

-- Called by InteractionController when the player releases the mouse.
function DragController.endDrag()
	pendingDrag = false
	if not dragState then
		return
	end
	local remotes = RemotesClient.get()
	remotes.DragEndRequest:FireServer()
	-- dragState is cleared when DragEnded arrives from server.
end

function DragController.isDragging(): boolean
	return dragState ~= nil
end

function DragController.isPending(): boolean
	return pendingDrag
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote events
-- ─────────────────────────────────────────────────────────────────────────────

local function onDragGranted(
	object:           Instance,
	primary:          BasePart,
	alignPosition:    AlignPosition,
	alignOrientation: AlignOrientation
)
	pendingDrag = false

	if not (object and primary) then
		return
	end
	if not (alignPosition and alignPosition:IsA("AlignPosition")) then
		return
	end
	if not (alignOrientation and alignOrientation:IsA("AlignOrientation")) then
		return
	end

	local camera = workspace.CurrentCamera
	-- Seed the grab-time orientation so the object doesn't snap on pickup.
	local grabOrientOffset = CFrame.identity
	if camera then
		grabOrientOffset = camera.CFrame.Rotation:Inverse() * primary.CFrame.Rotation
	end

	dragState = {
		object           = object,
		primary          = primary,
		alignPosition    = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance     = GeometryUtil.getHoldDistance(object),
		grabOrientOffset = grabOrientOffset,
	}
	inspectOffset = CFrame.identity
end

local function onDragEnded(_prop: Instance?)
	dragState   = nil
	pendingDrag = false
	inspecting  = false
	inspectOffset = CFrame.identity
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input: scroll wheel adjusts hold distance; inspect mode (gated).
-- ─────────────────────────────────────────────────────────────────────────────

UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	local ds = dragState
	if not ds then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		ds.holdDistance = math.clamp(
			ds.holdDistance - input.Position.Z * Config.Drag.scrollStep,
			Config.Drag.holdDistanceMin,
			Config.Drag.holdDistanceMax
		)
	end
end)

-- Inspect-rotate: gated off in v1 (Config.Drag.enableInspect = false).
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not Config.Drag.enableInspect then
		return
	end
	if (input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonL1) and dragState then
		inspecting = true
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if not Config.Drag.enableInspect then
		return
	end
	if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonL1 then
		inspecting = false
	end
end)

-- Accumulate inspect rotation when in inspect mode.
RunService:BindToRenderStep(
	"DragControllerInspect",
	Enum.RenderPriority.Input.Value,
	function(_dt: number)
		if not inspecting or not Config.Drag.enableInspect or not dragState then
			return
		end
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = 0.0125
			local step = CFrame.Angles(0, -delta.X * sensitivity, 0)
				* CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			inspectOffset = step * inspectOffset
		end
	end
)

-- ─────────────────────────────────────────────────────────────────────────────
-- Boot
-- ─────────────────────────────────────────────────────────────────────────────

function DragController.start()
	local remotes = RemotesClient.get()

	remotes.DragGranted.OnClientEvent:Connect(function(
		object: Instance,
		primary: BasePart,
		alignPosition: AlignPosition,
		alignOrientation: AlignOrientation
	)
		onDragGranted(object, primary, alignPosition, alignOrientation)
	end)

	remotes.DragEnded.OnClientEvent:Connect(function(prop: Instance?)
		onDragEnded(prop)
	end)

	-- Server-authoritative hold change forces a clean release.
	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "None" then
			onDragEnded(nil)
		end
	end)

	-- Per-frame steering.
	RunService:BindToRenderStep(
		"DragControllerSteering",
		Enum.RenderPriority.Camera.Value + 2,
		function(_dt: number)
			local camera = workspace.CurrentCamera
			if camera and dragState then
				steer(camera)
			end
		end
	)
end

return DragController
