--!strict
-- Module: InteractionController
-- Crosshair targeting, highlight/prompt, and input routing by item type.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))
local Types = require(Shared:WaitForChild("Types"))

local RemotesClient = require(script.Parent.RemotesClient)
local DragController = require(script.Parent.DragController)

type ItemKind = Types.ItemKind

local InteractionController = {}

local player = Players.LocalPlayer
local remotes: RemotesClient.RemotesClientTable? = nil
local character: Model? = player.Character
local targetObject: Instance? = nil
local targetKind: ItemKind = "None"
local holdKind: ItemKind = "None"
local camera = Workspace.CurrentCamera

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

local function setTarget(object: Instance?, kind: ItemKind)
	targetObject = object
	targetKind = kind

	if object and kind ~= "None" then
		highlight.Adornee = object
		highlight.Enabled = true
		if kind == "Weapon" then
			local weaponId = ItemRegistry.getWeaponId(object)
			local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
			local name = if def then def.displayName else "Weapon"
			setPrompt(string.format("[%s] Equip %s", Config.Input.equipKey.Name, name))
		elseif kind == "Prop" and holdKind == "None" and not DragController.isDragging() then
			setPrompt("Left Click: Grab")
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

function InteractionController.getHoldKind(): ItemKind
	return holdKind
end

function InteractionController.getTarget(): Instance?
	return targetObject
end

function InteractionController.onRenderStep()
	if holdKind ~= "None" or DragController.isDragging() then
		return
	end

	local cam = getCamera()
	if not cam then
		return
	end

	refreshRaycastFilter()

	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * Config.Drag.maxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	local foundKind: ItemKind = "None"
	if result then
		local object = ItemRegistry.resolveFromHit(result.Instance, Workspace)
		if object then
			local kind = ItemRegistry.classify(object)
			if kind == "Weapon" then
				found = object
				foundKind = "Weapon"
			elseif kind == "Prop" and ItemRegistry.isDraggable(object) then
				if object:GetAttribute(Config.Attributes.heldBy) == nil then
					found = object
					foundKind = "Prop"
				end
			end
		end
	end

	if found ~= targetObject or foundKind ~= targetKind then
		setTarget(found, foundKind)
	end
end

function InteractionController.onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not remotes then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if holdKind == "None" and not DragController.isDragging() and targetKind == "Prop" and targetObject then
			DragController.beginDrag(targetObject)
		end
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		return
	end

	if input.KeyCode == Config.Input.equipKey or input.KeyCode == Config.Input.gamepadEquipKey then
		if holdKind == "None" and targetKind == "Weapon" and targetObject then
			remotes.EquipRequest:FireServer(targetObject)
		end
	end
end

function InteractionController.onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and DragController.isDragging() then
		DragController.endDrag()
	end
end

function InteractionController.start(remoteTable: RemotesClient.RemotesClientTable)
	remotes = remoteTable

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean)
		if ok then
			holdKind = "Weapon"
			setTarget(nil, "None")
		end
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		holdKind = if kind == "Weapon" or kind == "Prop" or kind == "None" then kind :: ItemKind else "None"
		if holdKind ~= "Weapon" then
			setTarget(targetObject, targetKind)
		else
			setTarget(nil, "None")
		end
	end)

	remoteTable.DragGranted.OnClientEvent:Connect(function()
		holdKind = "Prop"
		setTarget(nil, "None")
	end)

	remoteTable.DragEnded.OnClientEvent:Connect(function()
		if holdKind == "Prop" then
			holdKind = "None"
		end
		setTarget(nil, "None")
	end)

	player.CharacterAdded:Connect(function(char)
		character = char
		holdKind = "None"
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

	refreshRaycastFilter()
end

return InteractionController
