--!strict
-- Module: client/DragController
-- PORTED constraint steering from the consensus client (BLUEPRINT.md §11.3),
-- bridged to a mouse-grab model with NO rotation:
--   * beginDrag(prop) is triggered by InteractionController on mouse-down.
--   * Once the server replies DragGranted, we steer the server-built
--     AlignPosition to a point in front of the camera every frame.
--   * The orientation goal is fixed at the grab orientation (decision #2); the
--     inspect-rotate path is present but gated behind Config.Drag.enableInspect.
--   * Releasing the mouse fires DragEndRequest; the fling is emergent.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local DRAG = Config.Drag

local DragController = {}

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	grabOrientation: CFrame,
	boundingRadius: number,
}

local remotes: any = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local hold: Hold? = nil
local pendingProp: Instance? = nil -- requested, awaiting DragGranted

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function computeHoldDistance(target: Instance): number
	local distance = DRAG.holdDistanceBase + GeometryUtil.getLargestAxis(target) * DRAG.holdDistancePadding
	return math.clamp(distance, DRAG.holdDistanceMin, DRAG.holdDistanceMax)
end

function DragController.isDragging(): boolean
	return hold ~= nil
end

-- Returns the instance currently held or pending (so InteractionController can
-- exclude it from targeting/raycast).
function DragController.getHeldObject(): Instance?
	if hold then
		return hold.object
	end
	return pendingProp
end

-- Called by InteractionController when the player mouse-presses a draggable prop
-- while empty-handed.
function DragController.beginDrag(prop: Instance)
	if hold or pendingProp then
		return
	end
	pendingProp = prop
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	pendingProp = nil
	if not hold then
		return
	end
	hold = nil
	remotes.DragEndRequest:FireServer()
end

local function onGranted(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	if not (object and primary and alignPosition and alignOrientation) then
		return
	end
	-- Ignore a grant we did not ask for (stale).
	if pendingProp and pendingProp ~= object then
		return
	end
	pendingProp = nil

	hold = {
		object = object,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = computeHoldDistance(object),
		-- Fixed orientation: props do not rotate (decision #2).
		grabOrientation = primary.CFrame.Rotation,
		boundingRadius = GeometryUtil.getBoundingRadius(object),
	}

	-- Quick-click guard: if the player already released the mouse before this
	-- grant arrived, drop immediately so the prop never sticks to an empty hand.
	if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		DragController.endDrag()
	end
end

-- Authoritative end from the server (normal drop, swap, leash, death).
local function onEnded()
	pendingProp = nil
	hold = nil
end

local function steer()
	local current = hold
	if not current then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end
	-- The server tore the rig down -> fall back to idle.
	if not current.primary.Parent or not current.alignPosition.Parent or not current.alignOrientation.Parent then
		hold = nil
		return
	end

	local camCF = cam.CFrame

	-- Client-side leash mirror: if the prop drifts beyond the server leash,
	-- proactively release so client and server agree.
	local maxDistance = DRAG.maxHoldDistance + current.boundingRadius
	if (current.primary.Position - camCF.Position).Magnitude > maxDistance then
		DragController.endDrag()
		return
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition
	-- No per-frame rotation: hold the grab orientation steady.
	current.alignOrientation.CFrame = current.grabOrientation
end

function DragController.start(remotesTable: any)
	remotes = remotesTable

	remotes.DragGranted.OnClientEvent:Connect(onGranted)
	remotes.DragEnded.OnClientEvent:Connect(onEnded)

	-- Any authoritative hold change to something other than this exact prop ends
	-- our local drag (e.g. a weapon equip swap superseded it).
	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?)
		if kind ~= "Prop" then
			onEnded()
		elseif hold and instance ~= hold.object then
			onEnded()
		end
	end)

	-- Release the grab when the mouse button is released.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			DragController.endDrag()
		end
	end)

	-- Scroll adjusts the hold distance (ported).
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
				current.holdDistance - input.Position.Z * DRAG.scrollStep,
				DRAG.holdDistanceMin,
				DRAG.holdDistanceMax
			)
		end
	end)

	-- Steer after the camera so we read the freshest CFrame.
	RunService:BindToRenderStep("ItemSystemDragSteer", Enum.RenderPriority.Camera.Value + 2, steer)

	player.CharacterAdded:Connect(function()
		onEnded()
	end)
end

return DragController
