--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local InteractionController = {}

local remotes: any = nil
local dragController: any = nil

local holdKind: "Weapon" | "Prop" | "None" = "None"
local currentTarget: Instance? = nil
local currentTargetKind: "Weapon" | "Prop" | "None" = "None"

local highlight: Highlight? = nil
local promptLabel: TextLabel? = nil

local function buildUi()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "ItemInteractionGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	highlight = Instance.new("Highlight")
	highlight.Name = "InteractionHighlight"
	highlight.FillTransparency = 0.8
	highlight.OutlineTransparency = 0
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineColor = Color3.fromRGB(255, 228, 148)
	highlight.Enabled = false
	highlight.Parent = gui

	local crosshair = Instance.new("Frame")
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(5, 5)
	crosshair.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	crosshair.BackgroundTransparency = 0.3
	crosshair.BorderSizePixel = 0
	crosshair.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = crosshair

	promptLabel = Instance.new("TextLabel")
	promptLabel.AnchorPoint = Vector2.new(0.5, 0)
	promptLabel.Position = UDim2.fromScale(0.5, 0.62)
	promptLabel.Size = UDim2.fromOffset(460, 30)
	promptLabel.BackgroundTransparency = 1
	promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptLabel.TextStrokeTransparency = 0.4
	promptLabel.Font = Enum.Font.GothamMedium
	promptLabel.TextSize = 21
	promptLabel.Text = ""
	promptLabel.Visible = false
	promptLabel.Parent = gui
end

local function setPrompt(text: string?)
	if not promptLabel then
		return
	end
	if text and text ~= "" then
		promptLabel.Text = text
		promptLabel.Visible = true
	else
		promptLabel.Visible = false
	end
end

local function updatePrompt()
	if holdKind == "Weapon" then
		setPrompt("[LMB] Fire   [R] Reload")
		return
	end
	if holdKind == "Prop" then
		setPrompt("[LMB Release] Drop")
		return
	end

	if currentTargetKind == "Weapon" then
		setPrompt(("[%s] Equip weapon"):format(Config.Input.equipKey.Name))
	elseif currentTargetKind == "Prop" then
		setPrompt("[LMB] Drag prop")
	else
		setPrompt(nil)
	end
end

local function raycastTarget()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(filter, character)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * Config.Validation.maxDragStartDistance, params)
	if not result then
		return nil
	end
	return ItemRegistry.resolveItemRoot(result.Instance)
end

local function updateTarget()
	if holdKind ~= "None" then
		currentTarget = nil
		currentTargetKind = "None"
		if highlight then
			highlight.Enabled = false
			highlight.Adornee = nil
		end
		updatePrompt()
		return
	end

	local target = raycastTarget()
	currentTarget = target
	currentTargetKind = ItemRegistry.classify(target)

	if highlight then
		highlight.Adornee = target
		highlight.Enabled = target ~= nil and currentTargetKind ~= "None"
	end
	updatePrompt()
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.Input.equipKey and holdKind == "None" and currentTargetKind == "Weapon" and currentTarget then
		remotes.EquipRequest:FireServer(currentTarget)
		return
	end

	if input.UserInputType == Config.Input.dragButton and holdKind == "None" and currentTargetKind == "Prop" and currentTarget then
		dragController.beginDrag(currentTarget)
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Config.Input.dragButton and dragController.isDragging() then
		dragController.endDrag()
	end
end

local function onHoldStateChanged(state: any)
	if typeof(state) ~= "table" then
		return
	end
	holdKind = state.kind
	updatePrompt()
end

function InteractionController.start(remoteMap: any, drag: any)
	remotes = remoteMap
	dragController = drag

	buildUi()
	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	RunService.RenderStepped:Connect(updateTarget)
end

return InteractionController
