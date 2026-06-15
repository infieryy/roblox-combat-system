--!strict
--[[
	InteractionController  (client/InteractionController.luau → StarterPlayerScripts.Client.InteractionController)
	----------------------------------------------------------------------------------------------------------------
	Ported from the consensus FirstPersonPickupClient targeting/highlight system,
	extended with item-type routing:

	  Weapon → "E to Equip" prompt; E fires EquipRequest.
	  Prop   → no E prompt; left-mouse-DOWN over prop calls DragController.beginDrag.
	  None   → clear prompt and highlight.

	Routing guard:
	  • Empty-handed left-click → DragController handles props.
	  • Weapon equipped left-click → WeaponController handles fire (InteractionController
	    does NOT call DragController when a weapon is held).
	  • E with weapon held → UnequipRequest (put gun away) fires via Q key in
	    WeaponController; here E is only used to EQUIP.

	Reacts to HoldStateChanged for crosshair/prompt state changes forced by server.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config"))
local ItemRegistry     = require(Shared:WaitForChild("ItemRegistry"))
local GeometryUtil     = require(Shared:WaitForChild("GeometryUtil"))
local RemotesClient    = require(script.Parent:WaitForChild("RemotesClient"))
local DragController   = require(script.Parent:WaitForChild("DragController"))

local LocalPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

local InteractionController = {}

local currentTarget: Instance?               = nil
local currentHoldKind: "Weapon"|"Prop"|"None" = "None"

-- ─────────────────────────────────────────────────────────────────────────────
-- Raycast setup
-- ─────────────────────────────────────────────────────────────────────────────

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshRayFilter()
	local filter: { Instance } = {}
	local character = LocalPlayer.Character
	if character then
		table.insert(filter, character)
	end
	rayParams.FilterDescendantsInstances = filter
end

-- Walk up from hit instance to the nearest classified ancestor.
local function resolveTarget(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= workspace do
		local kind = ItemRegistry.classify(node)
		if kind ~= "None" then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HUD
-- ─────────────────────────────────────────────────────────────────────────────

local gui = Instance.new("ScreenGui")
gui.Name           = "InteractionHud"
gui.ResetOnSpawn   = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

-- Dot crosshair.
local crosshair = Instance.new("Frame")
crosshair.Name             = "Crosshair"
crosshair.AnchorPoint      = Vector2.new(0.5, 0.5)
crosshair.Position         = UDim2.fromScale(0.5, 0.5)
crosshair.Size             = UDim2.fromOffset(6, 6)
crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
crosshair.BackgroundTransparency = 0.2
crosshair.BorderSizePixel  = 0
local crosshairCorner = Instance.new("UICorner")
crosshairCorner.CornerRadius = UDim.new(1, 0)
crosshairCorner.Parent = crosshair
crosshair.Parent = gui

-- Context prompt below crosshair.
local prompt = Instance.new("TextLabel")
prompt.Name              = "Prompt"
prompt.AnchorPoint       = Vector2.new(0.5, 0.5)
prompt.Position          = UDim2.fromScale(0.5, 0.62)
prompt.Size              = UDim2.fromOffset(400, 28)
prompt.BackgroundTransparency = 1
prompt.TextColor3        = Color3.new(1, 1, 1)
prompt.TextStrokeTransparency = 0.4
prompt.TextScaled        = false
prompt.TextSize          = 20
prompt.Font              = Enum.Font.GothamMedium
prompt.Text              = ""
prompt.Visible           = false
prompt.Parent            = gui

-- Highlight (shared Highlight instance so there is never more than one active).
local highlight = Instance.new("Highlight")
highlight.Name             = "InteractionHighlight"
highlight.FillTransparency  = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor         = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor      = Color3.fromRGB(255, 220, 120)
highlight.Enabled           = false
highlight.Parent            = gui

local function setTarget(object: Instance?)
	currentTarget = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true
		local kind = ItemRegistry.classify(object)
		if kind == "Weapon" then
			crosshair.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
			prompt.Text    = string.format("[E] Equip %s", object.Name)
			prompt.Visible = true
		elseif kind == "Prop" then
			crosshair.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
			prompt.Text    = "[Hold LMB] Grab"
			prompt.Visible = true
		end
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		crosshair.BackgroundColor3 = Color3.new(1, 1, 1)
		prompt.Visible = false
	end
end

-- Update crosshair tint to reflect current hold state.
local function updateHoldHud()
	if currentHoldKind == "Weapon" then
		crosshair.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
		prompt.Text    = "[Q] Unequip   •   [LMB] Fire   •   [R] Reload"
		prompt.Visible = true
	elseif currentHoldKind == "Prop" then
		crosshair.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
		prompt.Text    = "Release LMB to fling"
		prompt.Visible = true
	else
		-- Empty-handed: let targeting handle the HUD.
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-frame targeting
-- ─────────────────────────────────────────────────────────────────────────────

local function updateTargeting(camera: Camera)
	-- Suppress targeting while holding something.
	if currentHoldKind ~= "None" then
		if currentTarget then
			setTarget(nil)
		end
		updateHoldHud()
		return
	end
	-- Suppress while a drag is mid-flight.
	if DragController.isDragging() or DragController.isPending() then
		if currentTarget then
			setTarget(nil)
		end
		return
	end

	refreshRayFilter()

	local origin    = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * Config.Drag.maxPickupDistance

	local result = workspace:Raycast(origin, direction, rayParams)
	local found: Instance? = nil
	if result then
		local resolved = resolveTarget(result.Instance)
		if resolved then
			-- Skip if already held by another player.
			if resolved:GetAttribute(Config.HeldByAttribute) == nil then
				found = resolved
			end
		end
	end

	if found ~= currentTarget then
		setTarget(found)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input
-- ─────────────────────────────────────────────────────────────────────────────

local mouseIsDown = false

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	-- E key: equip a weapon.
	if input.KeyCode == Enum.KeyCode.E then
		if currentHoldKind == "None" and currentTarget then
			local kind = ItemRegistry.classify(currentTarget)
			if kind == "Weapon" then
				RemotesClient.get().EquipRequest:FireServer(currentTarget)
			end
		end
		return
	end

	-- Left mouse button: grab a prop (only when empty-handed).
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseIsDown = true
		if currentHoldKind == "None" and currentTarget then
			local kind = ItemRegistry.classify(currentTarget)
			if kind == "Prop" and ItemRegistry.isDraggable(currentTarget) then
				DragController.beginDrag(currentTarget)
			end
		end
		-- If weapon is held, WeaponController handles the click via its own InputBegan.
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseIsDown = false
		-- Release drag (fling).
		if DragController.isDragging() or DragController.isPending() then
			DragController.endDrag()
		end
	end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Boot
-- ─────────────────────────────────────────────────────────────────────────────

function InteractionController.start()
	local remotes = RemotesClient.get()

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, _weaponId: string?)
		currentHoldKind = kind :: any
		if kind ~= "None" then
			setTarget(nil)
		end
		updateHoldHud()
	end)

	-- Clear hold state on respawn.
	LocalPlayer.CharacterAdded:Connect(function()
		currentHoldKind = "None"
		setTarget(nil)
	end)

	RunService:BindToRenderStep(
		"InteractionControllerUpdate",
		Enum.RenderPriority.Camera.Value + 2,
		function(_dt: number)
			local camera = workspace.CurrentCamera
			if camera then
				updateTargeting(camera)
			end
		end
	)
end

-- Accessor used by other modules.
function InteractionController.getCurrentTarget(): Instance?
	return currentTarget
end

return InteractionController
