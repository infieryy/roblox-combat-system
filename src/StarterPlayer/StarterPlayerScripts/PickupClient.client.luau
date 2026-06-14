--!strict
--[[
	PickupClient
	------------
	First-person controller for the pickup system. Runs entirely on the local
	player and never has authority over physics or validation -- it only:
	  * Raycasts from the camera centre each frame to find a grabbable target.
	  * Sends pickup / drop requests on key press.
	  * While holding, computes the goal CFrame in front of the camera and
	    (a) drives the constraints locally for zero-lag feel (the holder owns
	        the assembly's physics), and
	    (b) streams the goal to the server over the unreliable channel for
	        replication to everyone else + server-side validation.
	  * Lets the player hold R and move the mouse to inspect/rotate the object
	    while the camera is temporarily frozen.

	Visuals: a reticle dot, a Highlight on the focused object, and a small
	prompt label.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PickupSystem = ReplicatedStorage:WaitForChild("PickupSystem")
local Config = require(PickupSystem:WaitForChild("Config"))
local PhysicsUtil = require(PickupSystem:WaitForChild("PhysicsUtil"))
local Remotes = require(PickupSystem:WaitForChild("Remotes"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

type State = {
	-- Idle targeting
	target: Instance?,
	lastHitPosition: Vector3?,

	-- Holding
	held: Instance?,
	handle: BasePart?,
	alignPosition: AlignPosition?,
	alignOrientation: AlignOrientation?,
	holdDistance: number,
	inspectRotation: CFrame,
	sendAccumulator: number,

	-- Inspecting (rotate)
	rotating: boolean,
	frozenCameraCFrame: CFrame?,
	previousCameraType: Enum.CameraType?,
}

local state: State = {
	target = nil,
	lastHitPosition = nil,
	held = nil,
	handle = nil,
	alignPosition = nil,
	alignOrientation = nil,
	holdDistance = Config.MinHoldDistance,
	inspectRotation = CFrame.identity,
	sendAccumulator = 0,
	rotating = false,
	frozenCameraCFrame = nil,
	previousCameraType = nil,
}

----------------------------------------------------------------------
-- UI (reticle, highlight, prompt)
----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PickupSystemUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(5, 5)
reticle.BackgroundColor3 = Color3.new(1, 1, 1)
reticle.BackgroundTransparency = 0.35
reticle.BorderSizePixel = 0
local reticleCorner = Instance.new("UICorner")
reticleCorner.CornerRadius = UDim.new(1, 0)
reticleCorner.Parent = reticle
reticle.Parent = gui

local prompt = Instance.new("TextLabel")
prompt.Name = "Prompt"
prompt.AnchorPoint = Vector2.new(0.5, 1)
prompt.Position = UDim2.fromScale(0.5, 0.82)
prompt.Size = UDim2.fromOffset(360, 28)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.GothamMedium
prompt.TextSize = 18
prompt.TextColor3 = Color3.new(1, 1, 1)
prompt.TextStrokeTransparency = 0.5
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "PickupHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 236, 150)
highlight.Enabled = false
highlight.Adornee = nil
highlight.Parent = gui

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter()
	local filter: { Instance } = { gui }
	if player.Character then
		table.insert(filter, player.Character)
	end
	raycastParams.FilterDescendantsInstances = filter
end

local function isInteractable(object: Instance): boolean
	if CollectionService:HasTag(object, Config.Tag) then
		return true
	end
	return object:GetAttribute(Config.Attribute) == true
end

-- Walk up from a hit part to find the tagged/attributed ancestor (so hitting
-- any child part of a grabbable model still resolves to that model).
local function resolveInteractable(hit: Instance): Instance?
	local current: Instance? = hit
	while current and current ~= Workspace do
		if isInteractable(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function setTarget(object: Instance?, hitPosition: Vector3?)
	state.target = object
	state.lastHitPosition = hitPosition

	if object then
		highlight.Adornee = object
		highlight.Enabled = true
		setPrompt(string.format("[%s] Pick Up", Config.PickupKey.Name))
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		if not state.held then
			setPrompt(nil)
		end
	end
end

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

----------------------------------------------------------------------
-- Inspect (rotate) mode
----------------------------------------------------------------------

local function startRotating()
	if state.rotating or not state.held then
		return
	end
	local camera = getCamera()
	if not camera then
		return
	end

	state.rotating = true
	state.frozenCameraCFrame = camera.CFrame
	state.previousCameraType = camera.CameraType
	-- Scriptable fully suspends the default camera so mouse movement no longer
	-- turns the view; we pin the CFrame ourselves and feed the delta into the
	-- object's rotation instead. Switching back to the prior type re-syncs the
	-- default camera to the current orientation, so there is no snap on exit.
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
end

local function stopRotating()
	if not state.rotating then
		return
	end
	state.rotating = false

	local camera = getCamera()
	if camera then
		camera.CameraType = state.previousCameraType or Enum.CameraType.Custom
	end
	state.frozenCameraCFrame = nil
	state.previousCameraType = nil
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

----------------------------------------------------------------------
-- Hold lifecycle (driven by server confirmations)
----------------------------------------------------------------------

local function beginHold(object: Instance)
	local handle = PhysicsUtil.getHandle(object)
	if not handle then
		return
	end

	state.held = object
	state.handle = handle
	state.alignPosition = handle:WaitForChild(PhysicsUtil.AlignPositionName, 3) :: AlignPosition?
	state.alignOrientation = handle:WaitForChild(PhysicsUtil.AlignOrientationName, 3) :: AlignOrientation?
	state.sendAccumulator = 0

	-- Frame the object based on its real size so big meshes sit further back.
	local largestAxis = PhysicsUtil.getLargestAxis(object)
	state.holdDistance = math.clamp(
		Config.HoldDistanceBase + largestAxis * Config.HoldDistanceSizeFactor,
		Config.MinHoldDistance,
		Config.MaxHoldDistanceClient
	)

	-- Seed the inspect rotation so the object keeps its current world
	-- orientation at the instant of pickup (no snap), expressed relative to the
	-- camera so it then turns naturally with the view.
	local camera = getCamera()
	if camera then
		state.inspectRotation = camera.CFrame.Rotation:Inverse() * handle.CFrame.Rotation
	else
		state.inspectRotation = CFrame.identity
	end

	setTarget(nil)
	setPrompt(string.format("[%s] Drop   •   Hold [%s] Rotate", Config.DropKey.Name, Config.RotateKey.Name))
end

local function endHold()
	state.held = nil
	state.handle = nil
	state.alignPosition = nil
	state.alignOrientation = nil
	state.inspectRotation = CFrame.identity
	if state.rotating then
		stopRotating()
	end
	setPrompt(nil)
end

----------------------------------------------------------------------
-- Per-frame update
----------------------------------------------------------------------

local function updateHold(camera: Camera, deltaTime: number)
	local handle = state.handle
	if not handle or not handle.Parent then
		-- The object vanished (destroyed/streamed out); fall back to idle.
		endHold()
		return
	end

	-- While inspecting, the camera is frozen so the object stays put and we
	-- accumulate mouse movement into its rotation instead.
	if state.rotating then
		local frozen = state.frozenCameraCFrame
		if frozen then
			camera.CFrame = frozen
		end
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = Config.RotateSensitivity
			local deltaRotation = CFrame.Angles(0, -delta.X * sensitivity, 0)
				* CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			state.inspectRotation = deltaRotation * state.inspectRotation
		end
	end

	local goalCFrame = camera.CFrame * CFrame.new(0, 0, -state.holdDistance)
	local goalPosition = goalCFrame.Position
	local goalRotation = camera.CFrame.Rotation * state.inspectRotation

	-- (a) Local prediction: we own the assembly, so writing the goal here makes
	-- the local simulation respond this very frame -- no round trip.
	if Config.ClientPrediction then
		if state.alignPosition then
			state.alignPosition.Position = goalPosition
		end
		if state.alignOrientation then
			state.alignOrientation.CFrame = goalRotation
		end
	end

	-- (b) Stream the goal to the server (throttled) for replication + auth.
	state.sendAccumulator += deltaTime
	if state.sendAccumulator >= Config.SendInterval then
		state.sendAccumulator = 0
		Remotes.UpdateGoal:FireServer(goalPosition, goalRotation)
	end
end

local function updateTargeting(camera: Camera)
	refreshRaycastFilter()

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * Config.MaxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local interactable: Instance? = nil
	local hitPosition: Vector3? = nil
	if result then
		interactable = resolveInteractable(result.Instance)
		hitPosition = result.Position
	end

	if interactable ~= state.target then
		setTarget(interactable, hitPosition)
	else
		state.lastHitPosition = hitPosition
	end
end

local function onRenderStep(deltaTime: number)
	local camera = getCamera()
	if not camera then
		return
	end

	if state.held then
		updateHold(camera, deltaTime)
	else
		updateTargeting(camera)
	end
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.PickupKey then
		if state.held then
			Remotes.DropRequest:FireServer()
		elseif state.target then
			Remotes.PickupRequest:FireServer(state.target, state.lastHitPosition)
		end
	elseif input.KeyCode == Config.DropKey then
		if state.held then
			Remotes.DropRequest:FireServer()
		end
	elseif input.KeyCode == Config.RotateKey then
		if state.held then
			startRotating()
		end
	end
end

local function onInputEnded(input: InputObject)
	if input.KeyCode == Config.RotateKey then
		stopRotating()
	end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------

Remotes.HoldStarted.OnClientEvent:Connect(function(object: Instance)
	beginHold(object)
end)

Remotes.HoldEnded.OnClientEvent:Connect(function()
	endHold()
end)

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

-- Bind just after the default camera so we read the freshest camera CFrame and,
-- when inspecting, can override it for that same frame.
RunService:BindToRenderStep(
	"PickupSystemUpdate",
	Enum.RenderPriority.Camera.Value + 1,
	onRenderStep
)

player.CharacterAdded:Connect(function()
	-- A respawn drops whatever we were holding (the server enforces this too).
	if state.held then
		endHold()
	end
	refreshRaycastFilter()
end)

refreshRaycastFilter()
