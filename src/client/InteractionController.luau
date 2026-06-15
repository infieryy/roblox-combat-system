--!strict
-- Module: Targeting, highlight, prompts, and item interaction routing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

type RemotesClientModule = typeof(require(script.Parent.RemotesClient))
type ClientRemotes = RemotesClientModule.ClientRemotes

type DragControllerApi = {
	beginDrag: (prop: Instance) -> (),
	endDrag: () -> (),
	isDragging: () -> boolean,
	getHeldObject: () -> Instance?,
}

local InteractionController = {}

local localPlayer = Players.LocalPlayer

local remotes: ClientRemotes? = nil
local dragController: DragControllerApi? = nil
local started = false

local holdKind: "Weapon" | "Prop" | "None" = "None"
local targetObject: Instance? = nil
local targetKind: "Weapon" | "Prop" | "None" = "None"
local character: Model? = localPlayer.Character

local gui = Instance.new("ScreenGui")
gui.Name = "ItemSystemUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(6, 6)
reticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
reticle.BackgroundTransparency = 0.3
reticle.BorderSizePixel = 0
local reticleCorner = Instance.new("UICorner")
reticleCorner.CornerRadius = UDim.new(1, 0)
reticleCorner.Parent = reticle
reticle.Parent = gui

local prompt = Instance.new("TextLabel")
prompt.Name = "Prompt"
prompt.AnchorPoint = Vector2.new(0.5, 1)
prompt.Position = UDim2.fromScale(0.5, 0.82)
prompt.Size = UDim2.fromOffset(540, 28)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.GothamMedium
prompt.TextSize = 18
prompt.TextColor3 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency = 0.5
prompt.Visible = false
prompt.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "ItemSystemHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
highlight.Enabled = false
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

local function setTarget(instance: Instance?, kind: "Weapon" | "Prop" | "None")
	targetObject = instance
	targetKind = kind
	if instance and kind ~= "None" then
		highlight.Adornee = instance
		highlight.Enabled = true
	else
		highlight.Adornee = nil
		highlight.Enabled = false
	end
end

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if character then
		table.insert(filter, character)
	end
	if dragController then
		local held = dragController.getHeldObject()
		if held then
			table.insert(filter, held)
		end
	end
	raycastParams.FilterDescendantsInstances = filter
end

local function resolveTarget(hit: Instance?): (Instance?, "Weapon" | "Prop" | "None")
	local node = hit
	while node and node ~= Workspace do
		local kind = ItemRegistry.classify(node)
		if kind ~= "None" then
			return node, kind
		end
		node = node.Parent
	end
	return nil, "None"
end

local function updateTargeting()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	refreshRaycastFilter()

	local result = Workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * Config.Drag.maxPickupDistance, raycastParams)
	if not result then
		if targetObject then
			setTarget(nil, "None")
		end
		return
	end

	local resolvedObject, resolvedKind = resolveTarget(result.Instance)
	if resolvedObject and resolvedKind == "Prop" then
		if resolvedObject:GetAttribute(Config.Drag.heldByAttribute) ~= nil then
			resolvedObject = nil
			resolvedKind = "None"
		end
	end
	if resolvedObject and resolvedKind == "Weapon" then
		local heldBy = resolvedObject:GetAttribute(Config.Drag.weaponHeldByAttribute)
		if heldBy and heldBy ~= localPlayer.UserId then
			resolvedObject = nil
			resolvedKind = "None"
		end
	end

	if resolvedObject ~= targetObject or resolvedKind ~= targetKind then
		setTarget(resolvedObject, resolvedKind)
	end
end

local function updatePrompt()
	if holdKind == "Weapon" then
		setPrompt("[Mouse1] Fire  •  [R] Reload  •  [E] Unequip")
		return
	end
	if dragController and dragController.isDragging() then
		setPrompt("[Mouse1 Release] Drop / Fling  •  Scroll: Distance")
		return
	end
	if targetKind == "Weapon" and targetObject then
		setPrompt("[E] Equip Weapon")
		return
	end
	if targetKind == "Prop" and targetObject and holdKind == "None" then
		setPrompt("[Mouse1 Hold] Drag Prop")
		return
	end
	setPrompt(nil)
end

local function onRenderStep()
	if holdKind ~= "Weapon" then
		updateTargeting()
	else
		setTarget(nil, "None")
	end
	updatePrompt()
end

function InteractionController.start(remoteBundle: ClientRemotes, dragApi: DragControllerApi)
	if started then
		return
	end
	started = true
	remotes = remoteBundle
	dragController = dragApi

	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	localPlayer.CharacterAdded:Connect(function(char: Model)
		character = char
		if dragController and dragController.isDragging() then
			dragController.endDrag()
		end
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "Weapon" or kind == "Prop" or kind == "None" then
			holdKind = kind
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if not remotes or not dragController then
			return
		end

		if input.KeyCode == Enum.KeyCode.E then
			if holdKind == "Weapon" then
				remotes.UnequipRequest:FireServer()
			elseif holdKind == "None" and targetKind == "Weapon" and targetObject then
				remotes.EquipRequest:FireServer(targetObject)
			end
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if holdKind == "None" and targetKind == "Prop" and targetObject then
				dragController.beginDrag(targetObject)
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragController then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and dragController.isDragging() then
			dragController.endDrag()
		end
	end)

	RunService:BindToRenderStep("ItemSystemInteraction", Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

return InteractionController
