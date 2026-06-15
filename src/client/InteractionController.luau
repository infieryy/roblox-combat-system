--!strict
-- Module: InteractionController
-- Per-frame raycast targeting, highlight, prompt, and input routing.
-- Ported from consensus FirstPersonPickupClient with the following changes:
--   * Routes by ItemRegistry.classify:
--       Weapon → "E to Equip" prompt; E key fires EquipRequest.
--       Prop   → no E; mouse-button-down fires DragController.beginDrag.
--       None   → clear prompt/highlight.
--   * E key no longer picks up props (reserved for weapons only).
--   * Mouse-button-1 release fires DragController.endDrag.
--   * React to HoldStateChanged to update crosshair/prompt state.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local Remotes        = require(script.Parent:WaitForChild("RemotesClient"))
local DragController = require(script.Parent:WaitForChild("DragController"))

local InteractionController = {}

local player   = Players.LocalPlayer
local camera   = Workspace.CurrentCamera

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

local targetObject: Instance? = nil
local currentHoldKind: "Weapon" | "Prop" | "None" = "None"
local character: Model? = player.Character

-- -------------------------------------------------------------------------
-- UI: reticle, highlight, prompt (ported from consensus)
-- -------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name           = "ItemSystemUI"
gui.ResetOnSpawn   = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent         = player:WaitForChild("PlayerGui")

local reticle                     = Instance.new("Frame")
reticle.Name                      = "Reticle"
reticle.AnchorPoint               = Vector2.new(0.5, 0.5)
reticle.Position                  = UDim2.fromScale(0.5, 0.5)
reticle.Size                      = UDim2.fromOffset(6, 6)
reticle.BackgroundColor3          = Color3.fromRGB(255, 255, 255)
reticle.BackgroundTransparency    = 0.35
reticle.BorderSizePixel           = 0
local reticleCorner               = Instance.new("UICorner")
reticleCorner.CornerRadius        = UDim.new(1, 0)
reticleCorner.Parent              = reticle
reticle.Parent                    = gui

local prompt                      = Instance.new("TextLabel")
prompt.Name                       = "Prompt"
prompt.AnchorPoint                = Vector2.new(0.5, 1)
prompt.Position                   = UDim2.fromScale(0.5, 0.82)
prompt.Size                       = UDim2.fromOffset(460, 28)
prompt.BackgroundTransparency     = 1
prompt.Font                       = Enum.Font.GothamMedium
prompt.TextSize                   = 18
prompt.TextColor3                 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency     = 0.5
prompt.Text                       = ""
prompt.Visible                    = false
prompt.Parent                     = gui

local highlight                   = Instance.new("Highlight")
highlight.Name                    = "PickupHighlight"
highlight.FillTransparency        = 0.85
highlight.OutlineTransparency     = 0
highlight.FillColor               = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor            = Color3.fromRGB(255, 220, 120)
highlight.Enabled                 = false
highlight.Adornee                 = nil
highlight.Parent                  = gui

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text    = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

-- -------------------------------------------------------------------------
-- Raycast filter
-- -------------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType   = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater  = true

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if character then table.insert(filter, character) end
	raycastParams.FilterDescendantsInstances = filter
end

-- -------------------------------------------------------------------------
-- Targeting
-- -------------------------------------------------------------------------

local function setTarget(object: Instance?)
	targetObject = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true

		local kind = ItemRegistry.classify(object)
		if kind == "Weapon" then
			setPrompt("[E] Equip")
		elseif kind == "Prop" then
			-- Prop: mouse-hold to grab, no E prompt needed
			setPrompt("Hold [LMB] to Grab")
		else
			setPrompt(nil)
		end
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		-- Only clear prompt if not currently holding something (hold prompt shown by hold state)
		if currentHoldKind == "None" then
			setPrompt(nil)
		end
	end
end

local function updateTargeting()
	refreshRaycastFilter()
	camera = Workspace.CurrentCamera
	if not camera then return end

	local origin    = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * Config.Drag.maxPickupDistance
	local result    = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	if result then
		local hit = result.Instance
		-- Walk up ancestry to find the interactable root
		local node: Instance? = hit
		while node and node ~= Workspace do
			local kind = ItemRegistry.classify(node)
			if kind ~= "None" then
				-- Skip if held by someone (PickupHeldBy attribute is set)
				if node:GetAttribute(Config.Drag.HeldByAttribute) == nil then
					found = node
				end
				break
			end
			node = node.Parent
		end
	end

	if found ~= targetObject then
		setTarget(found)
	end
end

-- -------------------------------------------------------------------------
-- Input routing
-- -------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	-- E key: equip weapon (only when target is a Weapon and player is empty-handed)
	if input.KeyCode == Enum.KeyCode.E then
		if currentHoldKind == "None" and targetObject then
			if ItemRegistry.classify(targetObject) == "Weapon" then
				Remotes.EquipRequest:FireServer(targetObject)
			end
		elseif currentHoldKind == "Weapon" then
			-- E while holding a weapon = unequip
			Remotes.UnequipRequest:FireServer()
		end
		return
	end

	-- Left mouse button: grab a prop (only when empty-handed and target is a draggable prop)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if currentHoldKind == "None" and targetObject then
			if ItemRegistry.isDraggable(targetObject) then
				DragController.beginDrag(targetObject)
			end
		end
		-- Note: if holding a weapon, MouseButton1 is handled by WeaponController.
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	-- Release mouse button: drop held prop
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if DragController.isDragging() then
			DragController.endDrag()
		end
	end
end)

-- -------------------------------------------------------------------------
-- React to hold state changes (from server)
-- -------------------------------------------------------------------------

Remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
	currentHoldKind = kind :: "Weapon" | "Prop" | "None"

	if kind == "None" then
		setPrompt(nil)
	elseif kind == "Prop" then
		setPrompt("[LMB Release] Drop   •   Scroll: Distance")
	elseif kind == "Weapon" then
		setPrompt("[Click] Fire   •   [R] Reload   •   [E] Unequip")
	end
end)

-- -------------------------------------------------------------------------
-- Character tracking
-- -------------------------------------------------------------------------

player.CharacterAdded:Connect(function(char)
	character = char
	refreshRaycastFilter()
	setTarget(nil)
	currentHoldKind = "None"
end)

-- -------------------------------------------------------------------------
-- RenderStep loop
-- -------------------------------------------------------------------------

-- start() called from init.client.luau.
function InteractionController.start(_dragController: any)
	if player.Character then
		character = player.Character
	end
	refreshRaycastFilter()

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = Workspace.CurrentCamera
	end)

	RunService:BindToRenderStep(
		"InteractionControllerUpdate",
		Enum.RenderPriority.Camera.Value + 1,
		function()
			-- Only scan for targets when not dragging and not holding a weapon
			if currentHoldKind == "None" then
				updateTargeting()
			else
				-- Clear targeting highlight when holding something
				if targetObject then
					setTarget(nil)
				end
			end
		end
	)
end

return InteractionController
