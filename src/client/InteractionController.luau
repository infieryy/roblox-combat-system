--!strict
-- Module: client/InteractionController.luau
-- Ported targeting/highlight from consensus build with item-type routing.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)
local DragController = require(script.Parent.DragController)
local WeaponController = require(script.Parent.WeaponController)

local InteractionController = {}

local remotes: {
	EquipRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
}? = nil

local player = Players.LocalPlayer
local character: Model? = player.Character
local targetObject: Instance? = nil
local holdKind: "Weapon" | "Prop" | "None" = "None"

local gui: ScreenGui
local reticle: Frame
local prompt: TextLabel
local highlight: Highlight

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function getCamera(): Camera?
	return Workspace.CurrentCamera
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

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

local function setTarget(object: Instance?)
	targetObject = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true
		local kind = ItemRegistry.classify(object)
		if kind == "Weapon" then
			setPrompt(string.format("[%s] Equip", Config.Input.equipKey.Name))
		elseif kind == "Prop" then
			setPrompt("Hold [Left Click] to Grab")
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
	if holdKind ~= "None" or DragController.isDragging() or WeaponController.isWeaponEquipped() then
		if targetObject then
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
		local object = ItemRegistry.resolveFromHit(result.Instance, Workspace)
		if object and object:GetAttribute(Config.HeldByAttribute) == nil then
			found = object
		end
	end

	if found ~= targetObject then
		setTarget(found)
	end
end

local function tryEquip()
	if not remotes or not targetObject then
		return
	end
	if ItemRegistry.classify(targetObject) ~= "Weapon" then
		return
	end
	remotes.EquipRequest:FireServer(targetObject)
end

local function tryBeginDrag()
	if holdKind ~= "None" or WeaponController.isWeaponEquipped() or DragController.isDragging() then
		return
	end
	if not targetObject then
		return
	end
	if ItemRegistry.classify(targetObject) ~= "Prop" or not ItemRegistry.isDraggable(targetObject) then
		return
	end
	DragController.beginDrag(targetObject)
end

function InteractionController.onRenderStep()
	local cam = getCamera()
	if not cam then
		return
	end
	updateTargeting(cam)
end

function InteractionController.onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.Input.equipKey or input.KeyCode == Config.Input.gamepadEquipKey then
		if holdKind == "None" and not DragController.isDragging() then
			tryEquip()
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if WeaponController.isWeaponEquipped() then
			return
		end
		if holdKind == "None" and not DragController.isDragging() then
			tryBeginDrag()
		end
	end
end

function InteractionController.onHoldStateChanged(kind: string, _instance: Instance?, _weaponId: string?)
	if kind == "Weapon" or kind == "Prop" or kind == "None" then
		holdKind = kind
	end

	if kind == "Prop" then
		setPrompt("Release [Left Click] to Drop / Fling")
	elseif kind == "Weapon" then
		setPrompt("Left Click: Fire  |  [R] Reload")
	elseif kind == "None" and not DragController.isDragging() then
		setPrompt(nil)
	end

	DragController.onHoldStateChanged(kind)
end

function InteractionController.configure(remoteTable: typeof(remotes))
	remotes = remoteTable
	if not remotes then
		return
	end

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?, weaponId: string?)
		InteractionController.onHoldStateChanged(kind, instance, weaponId)
	end)
end

function InteractionController.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "ItemSystemUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	reticle = Instance.new("Frame")
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

	prompt = Instance.new("TextLabel")
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

	highlight = Instance.new("Highlight")
	highlight.Name = "ItemHighlight"
	highlight.FillTransparency = 0.85
	highlight.OutlineTransparency = 0
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
	highlight.Enabled = false
	highlight.Parent = gui

	player.CharacterAdded:Connect(function(char: Model)
		character = char
		holdKind = "None"
		DragController.onCharacterAdded()
		refreshRaycastFilter()
	end)
	if player.Character then
		character = player.Character
	end
	refreshRaycastFilter()
end

return InteractionController
