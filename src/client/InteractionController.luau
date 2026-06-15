--!strict
-- Module: client/InteractionController
-- PORTED targeting/highlight/prompt from the consensus client (BLUEPRINT.md
-- §11.2) plus the NEW item-type routing that links the whole system together:
--   * Weapon  -> "[E] Equip"; pressing E fires EquipRequest.
--   * Prop    -> no E; mouse-down over a draggable prop (when empty-handed)
--                calls DragController.beginDrag — this is what hooks the new
--                routing into the existing dragging mechanic without breaking it.
--   * None    -> clear prompt/highlight.
-- Targeting only runs while empty-handed; with a weapon equipped, left-click is
-- owned by WeaponController (fire), and E holsters.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local DragController = require(script.Parent.DragController)

local DRAG = Config.Drag
local ATTR = Config.Attributes

local InteractionController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local characterRef: Model? = player.Character

local remotes: any = nil
local currentTarget: Instance? = nil
local currentKind: string = "None"
local holdKind: string = "None"

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

----------------------------------------------------------------------
-- UI: reticle, highlight, prompt (ported).
----------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "ItemSystemUI"
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
prompt.Size = UDim2.fromOffset(460, 28)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.GothamMedium
prompt.TextSize = 18
prompt.TextColor3 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency = 0.5
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "InteractHighlight"
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

----------------------------------------------------------------------
-- Raycasting (ported).
----------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if characterRef then
		table.insert(filter, characterRef)
	end
	local held = DragController.getHeldObject()
	if held then
		table.insert(filter, held)
	end
	raycastParams.FilterDescendantsInstances = filter
end

----------------------------------------------------------------------
-- Targeting + routing.
----------------------------------------------------------------------

local function promptForKind(kind: string, instance: Instance): string
	if kind == "Weapon" then
		local weaponId = ItemRegistry.getWeaponId(instance)
		local def = weaponId and ItemRegistry.getWeaponDef(weaponId)
		local name = def and def.displayName or "Weapon"
		return string.format("[E] Equip %s", name)
	elseif kind == "Prop" then
		return "Hold Mouse to Grab"
	end
	return ""
end

local function clearTarget()
	currentTarget = nil
	currentKind = "None"
	highlight.Adornee = nil
	highlight.Enabled = false
	if holdKind == "None" then
		setPrompt(nil)
	end
end

local function setTarget(instance: Instance?, kind: string)
	if instance == currentTarget and kind == currentKind then
		return
	end
	currentTarget = instance
	currentKind = kind
	if instance and kind ~= "None" then
		highlight.Adornee = instance
		highlight.Enabled = true
		setPrompt(promptForKind(kind, instance))
	else
		clearTarget()
	end
end

local function updateTargeting(cam: Camera)
	refreshRaycastFilter()

	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * DRAG.maxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local foundInstance: Instance? = nil
	local foundKind = "None"
	if result then
		local resolved, kind = ItemRegistry.resolve(result.Instance)
		if resolved then
			-- Skip props already held by someone else.
			if kind == "Prop" and resolved:GetAttribute(ATTR.heldBy) ~= nil then
				resolved = nil
			end
			if resolved then
				foundInstance = resolved
				foundKind = kind
			end
		end
	end

	if foundInstance ~= currentTarget or foundKind ~= currentKind then
		setTarget(foundInstance, foundKind)
	end
end

local function onRender()
	local cam = getCamera()
	if not cam then
		return
	end
	-- Targeting is only meaningful when empty-handed and not mid-grab.
	if holdKind == "None" and not DragController.isDragging() then
		updateTargeting(cam)
	elseif currentTarget then
		clearTarget()
	end
end

----------------------------------------------------------------------
-- Input.
----------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		if holdKind == "Weapon" then
			-- Holster the equipped weapon (frees the hand for props).
			remotes.UnequipRequest:FireServer()
		elseif holdKind == "None" and currentTarget and currentKind == "Weapon" then
			remotes.EquipRequest:FireServer(currentTarget)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- Empty-handed left-click on a draggable prop starts a grab. (With a
		-- weapon equipped, WeaponController owns left-click for firing.)
		if holdKind == "None" and not DragController.isDragging() then
			if currentTarget and currentKind == "Prop" and ItemRegistry.isDraggable(currentTarget) then
				DragController.beginDrag(currentTarget)
			end
		end
	end
end

----------------------------------------------------------------------
-- Hold-state reactions.
----------------------------------------------------------------------

local function onHoldStateChanged(kind: string)
	holdKind = kind
	if kind == "Weapon" then
		clearTarget()
		setPrompt("[E] Holster")
	elseif kind == "Prop" then
		clearTarget()
		setPrompt("Release Mouse to Drop  •  Scroll: Distance")
	else
		setPrompt(nil)
	end
end

----------------------------------------------------------------------
-- Start.
----------------------------------------------------------------------

function InteractionController.start(remotesTable: any)
	remotes = remotesTable

	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)

	UserInputService.InputBegan:Connect(onInputBegan)

	local function onCharacter(char: Model)
		characterRef = char
		refreshRaycastFilter()
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera then
			camera = Workspace.CurrentCamera
		end
	end)

	refreshRaycastFilter()
	RunService:BindToRenderStep("ItemSystemTargeting", Enum.RenderPriority.Camera.Value + 1, onRender)
end

return InteractionController
