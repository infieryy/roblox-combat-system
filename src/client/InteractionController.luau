--!strict
-- Module: InteractionController
-- Ported targeting, highlight, prompts, and item-type routing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local RemotesClient = require(script.Parent.RemotesClient)
local DragController = require(script.Parent.DragController)

type RemotesClientTable = RemotesClient.RemotesClientTable

local InteractionController = {}

local remotes: RemotesClientTable? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local character: Model? = player.Character
local targetObject: Instance? = nil
local holdKind: string = "None"
local weaponId: string? = nil

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
highlight.Name = "ItemHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
highlight.Enabled = false
highlight.Adornee = nil
highlight.Parent = gui

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if character then
		table.insert(filter, character)
	end
	local held = DragController.getHeldObject()
	if held then
		table.insert(filter, held)
	end
	raycastParams.FilterDescendantsInstances = filter
end

local function updatePromptForTarget(object: Instance?)
	if holdKind == "Weapon" then
		local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
		local name = if def then def.displayName else "Weapon"
		setPrompt(string.format("%s equipped  •  Click to fire  •  [R] Reload", name))
		return
	end

	if DragController.isDragging() then
		setPrompt("[Release] Drop / Fling  •  Scroll: Distance")
		return
	end

	if not object then
		setPrompt(nil)
		return
	end

	local kind = ItemRegistry.classify(object)
	if kind == "Weapon" then
		setPrompt(string.format("[%s] Equip", Config.Input.equipKey.Name))
	elseif kind == "Prop" then
		setPrompt("Hold [Left Click] to grab")
	else
		setPrompt(nil)
	end
end

local function setTarget(object: Instance?)
	targetObject = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true
	else
		highlight.Adornee = nil
		highlight.Enabled = false
	end
	updatePromptForTarget(object)
end

local function updateTargeting(cam: Camera)
	if holdKind ~= "None" or DragController.isDragging() then
		if holdKind == "Weapon" then
			setTarget(nil)
		end
		return
	end

	refreshRaycastFilter()
	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * Config.Drag.maxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	if result then
		local object = ItemRegistry.resolveInteractable(result.Instance)
		if object then
			local kind = ItemRegistry.classify(object)
			if kind == "Weapon" then
				local equippedBy = object:GetAttribute("EquippedBy")
				if equippedBy == nil or equippedBy == player.UserId then
					found = object
				end
			elseif kind == "Prop" and ItemRegistry.isDraggable(object) then
				found = object
			end
		end
	end

	if found ~= targetObject then
		setTarget(found)
	end
end

local function isEquipInput(input: InputObject): boolean
	return input.KeyCode == Config.Input.equipKey or input.KeyCode == Config.Input.gamepadEquipKey
end

function InteractionController.onHoldStateChanged(kind: string, instance: Instance?, newWeaponId: string?)
	holdKind = kind
	weaponId = newWeaponId
	DragController.onHoldStateChanged(kind)
	if kind ~= "None" then
		setTarget(nil)
	else
		targetObject = nil
		highlight.Enabled = false
	end
	updatePromptForTarget(targetObject)
end

local function onRenderStep()
	local cam = getCamera()
	if not cam then
		return
	end
	if holdKind == "None" and not DragController.isDragging() then
		updateTargeting(cam)
	else
		updatePromptForTarget(targetObject)
	end
end

function InteractionController.start(remotesTable: RemotesClientTable)
	remotes = remotesTable

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		if isEquipInput(input) and holdKind == "None" and not DragController.isDragging() then
			if targetObject and ItemRegistry.classify(targetObject) == "Weapon" and remotes then
				remotes.EquipRequest:FireServer(targetObject)
			end
			return
		end

		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			and holdKind == "None"
			and not DragController.isDragging()
			and targetObject
		then
			if ItemRegistry.classify(targetObject) == "Prop" and ItemRegistry.isDraggable(targetObject) then
				DragController.beginDrag(targetObject)
			end
		end
	end)

	remotesTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?, newWeaponId: string?)
		InteractionController.onHoldStateChanged(kind, instance, newWeaponId)
	end)

	player.CharacterAdded:Connect(function(char: Model)
		character = char
		refreshRaycastFilter()
	end)
	if player.Character then
		character = player.Character
	end

	refreshRaycastFilter()
	RunService:BindToRenderStep("InteractionControllerUpdate", Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

return InteractionController
