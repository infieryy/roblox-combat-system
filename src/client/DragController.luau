--!strict
-- Module: Client drag steering for server-created constraints.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))
type RemotesClientModule = typeof(require(script.Parent.RemotesClient))
type ClientRemotes = RemotesClientModule.ClientRemotes

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	orientationGoal: CFrame,
}

local DragController = {}

local localPlayer = Players.LocalPlayer
local remotes: ClientRemotes? = nil
local hold: Hold? = nil
local started = false

local function computeHoldDistance(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	local largestAxis = math.max(size.X, size.Y, size.Z)
	local distance = Config.Drag.holdDistanceBase + largestAxis * Config.Drag.holdDistancePadding
	return math.clamp(distance, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

local function endLocalHold()
	hold = nil
end

local function beginLocalHold(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	hold = {
		object = object,
		primary = primary,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		holdDistance = computeHoldDistance(object),
		orientationGoal = alignOrientation.CFrame,
	}
end

local function steerHold()
	local current = hold
	if not current then
		return
	end
	if not current.object:IsDescendantOf(Workspace) then
		endLocalHold()
		return
	end
	if not current.alignPosition.Parent or not current.alignOrientation.Parent then
		endLocalHold()
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local goalPosition = (camera.CFrame * CFrame.new(0, 0, -current.holdDistance)).Position
	current.alignPosition.Position = goalPosition
	current.alignOrientation.CFrame = current.orientationGoal

	local head = localPlayer.Character and localPlayer.Character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local distance = (current.primary.Position - head.Position).Magnitude
		if distance > Config.Drag.maxHoldDistance + GeometryUtil.getBoundingRadius(current.object) then
			DragController.endDrag()
		end
	end
end

function DragController.beginDrag(prop: Instance)
	if not remotes or hold then
		return
	end
	remotes.DragStartRequest:FireServer(prop)
end

function DragController.endDrag()
	if not remotes then
		return
	end
	remotes.DragEndRequest:FireServer()
end

function DragController.isDragging(): boolean
	return hold ~= nil
end

function DragController.getHeldObject(): Instance?
	local current = hold
	if current then
		return current.object
	end
	return nil
end

function DragController.start(remoteBundle: ClientRemotes)
	if started then
		return
	end
	started = true
	remotes = remoteBundle

	remotes.DragGranted.OnClientEvent:Connect(function(
		object: Instance,
		primary: BasePart,
		alignPosition: AlignPosition,
		alignOrientation: AlignOrientation
	)
		if not (object and primary and alignPosition and alignOrientation) then
			return
		end
		beginLocalHold(object, primary, alignPosition, alignOrientation)
	end)

	remotes.DragEnded.OnClientEvent:Connect(function()
		endLocalHold()
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind ~= "Prop" then
			endLocalHold()
		end
	end)

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
				current.holdDistance - input.Position.Z * Config.Drag.scrollStep,
				Config.Drag.holdDistanceMin,
				Config.Drag.holdDistanceMax
			)
		end
	end)

	RunService:BindToRenderStep("ItemSystemDragSteer", Enum.RenderPriority.Camera.Value + 1, steerHold)
end

return DragController
