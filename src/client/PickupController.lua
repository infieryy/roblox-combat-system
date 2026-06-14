--[[
	PickupController (client controller)
	------------------------------------------------------------------
	Owns the first-person experience:

	  * A custom Scriptable first-person camera (mouse-locked, pitch
	    clamped) anchored to the player's head.
	  * A per-frame raycast from the camera center that highlights any
	    interactable in view and shows a contextual prompt.
	  * Input: press E to pick up / drop, hold R + move the mouse to spin
	    the held object in front of your face, scroll to push/pull it.
	  * Because the server gives this client network ownership of the held
	    object, we drive the AlignPosition/AlignOrientation goals locally
	    every frame for lag-free dragging.

	No per-frame remotes are sent -- only the pickup/drop intents.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupSystem = ReplicatedStorage:WaitForChild("PickupSystem")
local Config = require(PickupSystem:WaitForChild("Config"))
local PhysicsUtil = require(PickupSystem:WaitForChild("PhysicsUtil"))
local Remotes = require(PickupSystem:WaitForChild("Remotes"))

local PickupController = {}

local player = Players.LocalPlayer

type Held = {
	object: Instance,
	driver: BasePart,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	boundingRadius: number,
	holdDistance: number,
}

-- Mutable runtime state for the local player.
local state = {
	camera = Workspace.CurrentCamera,
	character = nil :: Model?,
	root = nil :: BasePart?,
	characterParts = {} :: { BasePart },
	yaw = 0,
	pitch = 0,
	target = nil :: Instance?,
	held = nil :: Held?,
	inspecting = false,
	inspectRotation = CFrame.identity,
}

local remotes: Remotes.RemoteMap
local highlight: Highlight
local promptLabel: TextLabel

local PITCH_LIMIT = math.rad(Config.PitchLimit)

------------------------------------------------------------------
-- UI (highlight + prompt)
------------------------------------------------------------------

local function buildUi()
	highlight = Instance.new("Highlight")
	highlight.Name = "PickupHighlight"
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0.85
	highlight.OutlineColor = Color3.fromRGB(255, 236, 150)
	highlight.OutlineTransparency = 0
	highlight.Enabled = false
	highlight.Parent = Workspace

	local gui = Instance.new("ScreenGui")
	gui.Name = "PickupPrompt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	promptLabel = Instance.new("TextLabel")
	promptLabel.AnchorPoint = Vector2.new(0.5, 1)
	promptLabel.Position = UDim2.new(0.5, 0, 0.85, 0)
	promptLabel.Size = UDim2.new(0, 420, 0, 36)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Font = Enum.Font.GothamMedium
	promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	promptLabel.TextStrokeTransparency = 0.4
	promptLabel.TextScaled = false
	promptLabel.TextSize = 22
	promptLabel.Text = ""
	promptLabel.Parent = gui

	-- A small fixed crosshair so the player knows where the raycast points.
	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.new(0.5, 0, 0.5, 0)
	crosshair.Size = UDim2.new(0, 4, 0, 4)
	crosshair.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	crosshair.BackgroundTransparency = 0.3
	crosshair.BorderSizePixel = 0
	crosshair.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = crosshair
end

local function updatePrompt()
	if not promptLabel then
		return
	end
	if state.held then
		promptLabel.Text = "[E] Drop      Hold [R] + move mouse to inspect      Scroll to push/pull"
	elseif state.target then
		promptLabel.Text = "[E] Pick up"
	else
		promptLabel.Text = ""
	end
end

local function setTarget(target: Instance?)
	if state.target == target then
		return
	end
	state.target = target
	highlight.Adornee = target
	highlight.Enabled = target ~= nil
	updatePrompt()
end

------------------------------------------------------------------
-- Character / camera setup
------------------------------------------------------------------

local function cacheCharacterParts(character: Model)
	state.characterParts = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(state.characterParts, descendant)
		end
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			table.insert(state.characterParts, descendant)
		end
	end)
end

local function onCharacterAdded(character: Model)
	state.character = character
	state.root = character:WaitForChild("HumanoidRootPart") :: BasePart
	cacheCharacterParts(character)

	-- Seed the camera yaw from the spawn facing so the view doesn't jump.
	local _, spawnYaw = state.root.CFrame:ToOrientation()
	state.yaw = spawnYaw
	state.pitch = 0

	state.camera = Workspace.CurrentCamera
	state.camera.CameraType = Enum.CameraType.Scriptable
end

------------------------------------------------------------------
-- Per-frame: camera
------------------------------------------------------------------

local function updateCamera(_dt: number)
	local root = state.root
	local camera = state.camera
	if not root or not camera then
		return
	end

	-- Keep the mouse locked & hidden every frame (other systems can reset it).
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	local delta = UserInputService:GetMouseDelta()

	if state.held and state.inspecting then
		-- Redirect mouse movement into spinning the held object; the camera
		-- itself stays frozen this frame.
		local rx = math.rad(-delta.Y * Config.RotateSensitivity)
		local ry = math.rad(-delta.X * Config.RotateSensitivity)
		state.inspectRotation = CFrame.Angles(0, ry, 0)
			* CFrame.Angles(rx, 0, 0)
			* state.inspectRotation
	else
		state.yaw -= math.rad(delta.X * Config.LookSensitivity)
		state.pitch = math.clamp(
			state.pitch - math.rad(delta.Y * Config.LookSensitivity),
			-PITCH_LIMIT,
			PITCH_LIMIT
		)
	end

	local eye = root.Position + Config.EyeOffset
	camera.CFrame = CFrame.new(eye)
		* CFrame.Angles(0, state.yaw, 0)
		* CFrame.Angles(state.pitch, 0, 0)

	-- Hide the local body so it never blocks the first-person view.
	if Config.HideCharacterInFirstPerson then
		for _, part in state.characterParts do
			part.LocalTransparencyModifier = 1
		end
	end
end

------------------------------------------------------------------
-- Per-frame: targeting raycast
------------------------------------------------------------------

local function updateTargeting()
	if state.held or not state.character then
		setTarget(nil)
		return
	end

	local camera = state.camera
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { state.character }
	params.IgnoreWater = true

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * Config.MaxPickupDistance
	local result = Workspace:Raycast(origin, direction, params)

	local found: Instance? = nil
	if result then
		found = PhysicsUtil.resolveInteractable(result.Instance)
	end
	setTarget(found)
end

------------------------------------------------------------------
-- Per-frame: drive the held object
------------------------------------------------------------------

local function updateHeld()
	local held = state.held
	if not held then
		return
	end
	if not held.driver or not held.driver.Parent then
		state.held = nil
		updatePrompt()
		return
	end

	local camera = state.camera
	local holdPosition = (camera.CFrame * CFrame.new(0, 0, -held.holdDistance)).Position

	-- We own this assembly's physics, so writing the goals locally moves
	-- it instantly on our screen and replicates out via network ownership.
	held.alignPosition.Position = holdPosition
	held.alignOrientation.CFrame = camera.CFrame.Rotation * state.inspectRotation
end

------------------------------------------------------------------
-- Input
------------------------------------------------------------------

local function requestPickup()
	if state.target then
		remotes.RequestPickup:FireServer(state.target)
	end
end

local function requestDrop()
	remotes.RequestDrop:FireServer()
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Config.PickupKey then
		if state.held then
			requestDrop()
		else
			requestPickup()
		end
	elseif input.KeyCode == Config.RotateKey then
		if state.held then
			state.inspecting = true
		end
	end
end

local function onInputEnded(input: InputObject)
	if input.KeyCode == Config.RotateKey then
		state.inspecting = false
	end
end

local function onInputChanged(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel and state.held then
		local held = state.held
		held.holdDistance = math.clamp(
			held.holdDistance - input.Position.Z * Config.ScrollStep,
			Config.MinHoldDistance,
			Config.MaxHoldDistance + held.boundingRadius
		)
	end
end

------------------------------------------------------------------
-- Remote handlers
------------------------------------------------------------------

local function onPickupGranted(data: any)
	state.inspectRotation = CFrame.identity
	state.inspecting = false

	local radius = data.boundingRadius or PhysicsUtil.getBoundingRadius(data.object)
	local holdDistance = math.clamp(
		Config.HoldDistance + radius * Config.HoldDistancePadding,
		Config.MinHoldDistance,
		Config.MaxHoldDistance + radius
	)

	state.held = {
		object = data.object,
		driver = data.driver,
		alignPosition = data.alignPosition,
		alignOrientation = data.alignOrientation,
		boundingRadius = radius,
		holdDistance = holdDistance,
	}
	setTarget(nil)
	updatePrompt()
end

local function onPickupEnded()
	state.held = nil
	state.inspecting = false
	state.inspectRotation = CFrame.identity
	updatePrompt()
end

------------------------------------------------------------------
-- Start
------------------------------------------------------------------

function PickupController.Start()
	remotes = Remotes.get()

	while not Workspace.CurrentCamera do
		task.wait()
	end
	state.camera = Workspace.CurrentCamera

	buildUi()

	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	-- If we respawn or die while carrying, make sure we stop holding.
	player.CharacterRemoving:Connect(function()
		if state.held then
			requestDrop()
		end
		onPickupEnded()
	end)

	remotes.PickupGranted.OnClientEvent:Connect(onPickupGranted)
	remotes.PickupEnded.OnClientEvent:Connect(onPickupEnded)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.InputChanged:Connect(onInputChanged)

	RunService:BindToRenderStep("PickupCamera", Enum.RenderPriority.Camera.Value, updateCamera)
	RunService:BindToRenderStep("PickupUpdate", Enum.RenderPriority.Camera.Value + 1, function()
		updateTargeting()
		updateHeld()
	end)
end

return PickupController
