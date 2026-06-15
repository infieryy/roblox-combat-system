--!strict
-- Module: InteractionController
-- Targeting, highlight, prompts, and input routing by item type.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)

local DragController = require(script.Parent.DragController)

type Remotes = typeof(require(script.Parent.RemotesClient).waitForRemotes())

local InteractionController = {}

local remotes: Remotes? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local character: Model? = player.Character
local targetObject: Instance? = nil
local holdKind: "Weapon" | "Prop" | "None" = "None"
local mouseHeld = false

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
prompt.Size = UDim2.fromOffset(480, 28)
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

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function setTarget(object: Instance?, kind: "Weapon" | "Prop" | "None")
	targetObject = object
	if object and kind ~= "None" then
		highlight.Adornee = object
		highlight.Enabled = true
		if kind == "Weapon" and holdKind == "None" and not DragController.isDragging() then
			local def = ItemRegistry.getWeaponDef(ItemRegistry.getWeaponId(object) or "")
			local name = if def then def.displayName else "Weapon"
			setPrompt(string.format("[%s] Equip %s", Config.Input.equipKey.Name, name))
		elseif kind == "Prop" and holdKind == "None" and not DragController.isDragging() then
			setPrompt("Hold [LMB] to Grab")
		else
			setPrompt(nil)
		end
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		if holdKind == "None" and not DragController.isDragging() then
			setPrompt(nil)
		end
	end
end

local function updateTargeting(cam: Camera)
	if holdKind ~= "None" or DragController.isDragging() then
		if holdKind == "Prop" or DragController.isDragging() then
			setPrompt(string.format("[%s] Drop   •   Scroll: Distance", Config.Input.dropKey.Name))
		end
		return
	end

	refreshRaycastFilter()
	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * Config.Drag.maxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	local foundKind: "Weapon" | "Prop" | "None" = "None"
	if result then
		local object = ItemRegistry.resolveFromHit(result.Instance, Workspace)
		if object then
			local kind = ItemRegistry.classify(object)
			if kind == "Weapon" or (kind == "Prop" and ItemRegistry.isDraggable(object)) then
				found = object
				foundKind = kind
			end
		end
	end

	if found ~= targetObject then
		setTarget(found, foundKind)
	end
end

local function isEquipInput(input: InputObject): boolean
	return input.KeyCode == Config.Input.equipKey or input.KeyCode == Config.Input.gamepadEquipKey
end

function InteractionController.start(remoteTable: Remotes)
	remotes = remoteTable

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "Weapon" or kind == "Prop" or kind == "None" then
			holdKind = kind
		end
		if kind == "Weapon" then
			setTarget(nil, "None")
			setPrompt("[LMB] Fire   •   [R] Reload")
		elseif kind == "None" and not DragController.isDragging() then
			setPrompt(nil)
		end
	end)

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean)
		if ok then
			holdKind = "Weapon"
			setTarget(nil, "None")
			setPrompt("[LMB] Fire   •   [R] Reload")
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		if isEquipInput(input) then
			if holdKind == "Weapon" then
				remotes.UnequipRequest:FireServer()
			elseif holdKind == "None" and not DragController.isDragging() and targetObject then
				local kind = ItemRegistry.classify(targetObject)
				if kind == "Weapon" then
					remotes.EquipRequest:FireServer(targetObject)
				end
			end
		elseif input.KeyCode == Config.Input.dropKey then
			if DragController.isDragging() then
				DragController.endDrag()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			if holdKind == "None" and not DragController.isDragging() and targetObject then
				local kind = ItemRegistry.classify(targetObject)
				if kind == "Prop" then
					mouseHeld = true
					DragController.beginDrag(targetObject)
				end
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and mouseHeld then
			mouseHeld = false
			if DragController.isDragging() then
				DragController.endDrag()
			end
		end
	end)

	player.CharacterAdded:Connect(function(char: Model)
		character = char
		holdKind = "None"
		DragController.onCharacterChanged()
		refreshRaycastFilter()
	end)
	if player.Character then
		character = player.Character
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera then
			camera = Workspace.CurrentCamera
		end
	end)

	if Config.Input.forceFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end

	refreshRaycastFilter()

	RunService:BindToRenderStep("InteractionControllerUpdate", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = getCamera()
		if cam then
			updateTargeting(cam)
		end
	end)
end

return InteractionController
