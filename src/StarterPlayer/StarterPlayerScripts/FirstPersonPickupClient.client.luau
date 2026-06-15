--!strict
--[[
	FirstPersonPickupClient  (LocalScript -> StarterPlayer/StarterPlayerScripts)
	===========================================================================
	MASTER CONSENSUS BUILD of the first-person pickup & inspection controller.

	A single, self-contained client script (the synthesised "best of" 10
	independently generated implementations). It:

	  * Locks the player into first person.
	  * Raycasts from the camera centre every frame, highlighting whatever
	    interactable it is looking at and showing a contextual prompt.
	  * E  -> pick up what you are looking at (or drop what you hold).
	  * Q  -> drop.
	  * R (hold) -> "inspection" mode: the view freezes and the mouse rotates
	    the held object in place (My-Summer-Car style).
	  * Mouse wheel -> push the held object further away / pull it closer.

	Because the server transfers network ownership of the held object to us, we
	steer the AlignPosition / AlignOrientation goals locally every frame. The
	drag is therefore simulated on our own machine = zero perceived lag, and the
	motion replicates outward to the server and other players automatically.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------------
-- Configuration (client-relevant subset; must match PickupServer's Config).
----------------------------------------------------------------------

local Config = {
	-- Detection
	Tag = "Interactable",
	Attribute = "Interactable",
	HeldByAttribute = "PickupHeldBy",

	-- Reach
	MaxPickupDistance = 12,

	-- Hold framing: the object floats this far in front of the camera, scaled
	-- up by its size so large meshes are pushed back to stay fully in frame.
	HoldDistanceBase = 4,
	HoldDistancePadding = 1.0,
	HoldDistanceMin = 3,
	HoldDistanceMax = 10,
	-- Studs per mouse-wheel notch.
	ScrollStep = 0.75,

	-- Inspection: radians of object rotation per pixel of mouse movement.
	RotateSensitivity = 0.0125,

	-- Input
	PickupKey = Enum.KeyCode.E,
	DropKey = Enum.KeyCode.Q,
	RotateKey = Enum.KeyCode.R,
	GamepadPickupKey = Enum.KeyCode.ButtonR1,
	GamepadRotateKey = Enum.KeyCode.ButtonL1,

	-- Misc
	ForceFirstPerson = true,
	RemotesFolderName = "PickupSystemRemotes",
}

----------------------------------------------------------------------
-- Remotes.
----------------------------------------------------------------------

local remotesFolder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
local PickupRequest = remotesFolder:WaitForChild("PickupRequest") :: RemoteEvent
local DropRequest = remotesFolder:WaitForChild("DropRequest") :: RemoteEvent
local PickupGranted = remotesFolder:WaitForChild("PickupGranted") :: RemoteEvent
local PickupEnded = remotesFolder:WaitForChild("PickupEnded") :: RemoteEvent

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

----------------------------------------------------------------------
-- State.
----------------------------------------------------------------------

type Hold = {
	object: Instance,
	primary: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	holdDistance: number,
	rotationOffset: CFrame,
}

local character: Model? = player.Character
local targetObject: Instance? = nil
local hold: Hold? = nil

local rotating = false
local frozenCameraCFrame: CFrame? = nil

----------------------------------------------------------------------
-- Geometry helpers.
----------------------------------------------------------------------

local function getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

local function getLargestAxis(target: Instance): number
	local _, size = getBoundingBox(target)
	return math.max(size.X, size.Y, size.Z)
end

local function computeHoldDistance(target: Instance): number
	local distance = Config.HoldDistanceBase + getLargestAxis(target) * Config.HoldDistancePadding
	return math.clamp(distance, Config.HoldDistanceMin, Config.HoldDistanceMax)
end

local function isInteractable(instance: Instance): boolean
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return false
	end
	if CollectionService:HasTag(instance, Config.Tag) then
		return true
	end
	return instance:GetAttribute(Config.Attribute) == true
end

local function resolveInteractable(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= Workspace do
		if isInteractable(node) then
			return node
		end
		node = node.Parent
	end
	return nil
end

----------------------------------------------------------------------
-- UI: reticle, highlight, prompt.
----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PickupSystemUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(6, 6)
reticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
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
prompt.Size = UDim2.fromOffset(420, 28)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.GothamMedium
prompt.TextSize = 18
prompt.TextColor3 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency = 0.5
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "PickupHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
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

local function holdPromptText(): string
	return string.format("[%s] Drop   •   Hold [%s] Inspect   •   Scroll: Distance", Config.DropKey.Name, Config.RotateKey.Name)
end

----------------------------------------------------------------------
-- Raycasting.
----------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if character then
		table.insert(filter, character)
	end
	if hold then
		table.insert(filter, hold.object)
	end
	raycastParams.FilterDescendantsInstances = filter
end

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

----------------------------------------------------------------------
-- Targeting (only while empty-handed).
----------------------------------------------------------------------

local function setTarget(object: Instance?)
	targetObject = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true
		setPrompt(string.format("[%s] Pick Up", Config.PickupKey.Name))
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		if not hold then
			setPrompt(nil)
		end
	end
end

local function updateTargeting(cam: Camera)
	refreshRaycastFilter()

	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * Config.MaxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	if result then
		local object = resolveInteractable(result.Instance)
		-- Skip objects already held by someone.
		if object and object:GetAttribute(Config.HeldByAttribute) == nil then
			found = object
		end
	end

	if found ~= targetObject then
		setTarget(found)
	end
end

----------------------------------------------------------------------
-- Inspection (hold R) mode.
----------------------------------------------------------------------

local function startInspect()
	if rotating or not hold then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end
	rotating = true
	frozenCameraCFrame = cam.CFrame
	-- Scriptable suspends the default camera so the mouse no longer turns the
	-- view; we pin the CFrame ourselves and feed the delta into the object.
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
-- Holding: steer the constraint goals locally each frame.
----------------------------------------------------------------------

local function steerHold(cam: Camera)
	local current = hold
	if not current then
		return
	end
	-- The object vanished or the server tore the rig down -> fall back to idle.
	if not current.primary.Parent or not current.alignPosition.Parent or not current.alignOrientation.Parent then
		return
	end

	local camCF = (rotating and frozenCameraCFrame) or cam.CFrame
	if rotating and frozenCameraCFrame then
		-- Keep the first-person view pinned while inspecting and convert mouse
		-- movement into object rotation instead.
		cam.CFrame = frozenCameraCFrame
		local delta = UserInputService:GetMouseDelta()
		if delta.Magnitude > 0 then
			local sensitivity = Config.RotateSensitivity
			local deltaRotation = CFrame.Angles(0, -delta.X * sensitivity, 0) * CFrame.Angles(-delta.Y * sensitivity, 0, 0)
			current.rotationOffset = deltaRotation * current.rotationOffset
		end
	end

	local goalPosition = (camCF * CFrame.new(0, 0, -current.holdDistance)).Position
	local goalRotation = camCF.Rotation * current.rotationOffset

	current.alignPosition.Position = goalPosition
	current.alignOrientation.CFrame = goalRotation
end

----------------------------------------------------------------------
-- Hold lifecycle (driven by server confirmations).
----------------------------------------------------------------------

local function beginHold(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	local cam = getCamera()

	-- Seed the rotation offset so the object keeps its current orientation at
	-- the instant of pickup (no snap), expressed relative to the camera so it
	-- then turns naturally with the view.
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

	setTarget(nil)
	refreshRaycastFilter()
	setPrompt(holdPromptText())
end

local function endHold()
	hold = nil
	if rotating then
		stopInspect()
	end
	refreshRaycastFilter()
	setPrompt(nil)
end

----------------------------------------------------------------------
-- Main loop.
----------------------------------------------------------------------

local function onRenderStep()
	local cam = getCamera()
	if not cam then
		return
	end
	if hold then
		steerHold(cam)
	else
		updateTargeting(cam)
	end
end

----------------------------------------------------------------------
-- Input.
----------------------------------------------------------------------

local function isPickupInput(input: InputObject): boolean
	return input.KeyCode == Config.PickupKey or input.KeyCode == Config.GamepadPickupKey
end

local function isRotateInput(input: InputObject): boolean
	return input.KeyCode == Config.RotateKey or input.KeyCode == Config.GamepadRotateKey
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if isPickupInput(input) then
		if hold then
			DropRequest:FireServer()
		elseif targetObject then
			PickupRequest:FireServer(targetObject)
		end
	elseif input.KeyCode == Config.DropKey then
		if hold then
			DropRequest:FireServer()
		end
	elseif isRotateInput(input) then
		if hold then
			startInspect()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if isRotateInput(input) then
		stopInspect()
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
			current.holdDistance - input.Position.Z * Config.ScrollStep,
			Config.HoldDistanceMin,
			Config.HoldDistanceMax
		)
	end
end)

----------------------------------------------------------------------
-- Net handlers.
----------------------------------------------------------------------

PickupGranted.OnClientEvent:Connect(function(object: Instance, primary: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation)
	if not (object and primary and alignPosition and alignOrientation) then
		return
	end
	beginHold(object, primary, alignPosition, alignOrientation)
end)

PickupEnded.OnClientEvent:Connect(function()
	endHold()
end)

----------------------------------------------------------------------
-- Character lifecycle + first person.
----------------------------------------------------------------------

local function onCharacter(char: Model)
	character = char
	-- A respawn drops whatever we were holding (the server enforces this too).
	if hold then
		endHold()
	end
	refreshRaycastFilter()
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end

if Config.ForceFirstPerson then
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if Workspace.CurrentCamera then
		camera = Workspace.CurrentCamera
	end
end)

refreshRaycastFilter()

-- Bind just after the default camera so we read the freshest camera CFrame and,
-- while inspecting, can override it for that same frame.
RunService:BindToRenderStep("FirstPersonPickupUpdate", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
