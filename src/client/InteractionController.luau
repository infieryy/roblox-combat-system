--!strict
-- Module: client/InteractionController
-- Ported targeting / highlight / prompt from the consensus client, plus the new
-- routing rule:
--   * Weapon  -> show "[E] Equip"; press E -> EquipRequest.
--   * Prop    -> no E; mouse-down over a draggable prop -> DragController.beginDrag.
--               (Only when empty-handed; a gun owns left-click for firing.)
--   * None    -> clear prompt/highlight.
-- Targeting only runs while empty-handed, exactly like the consensus build.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

local DragCfg = Config.Drag

local InteractionController = {}

local ctx: Context = nil :: any
local player = Players.LocalPlayer

local character: Model? = player.Character
local currentKind: string = "None" -- authoritative, from HoldStateChanged
local target: Instance? = nil
local targetKind: string = "None"

----------------------------------------------------------------------
-- UI.
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
highlight.Name = "TargetHighlight"
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
-- Raycasting.
----------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter()
	local filter: { Instance } = {}
	if character then
		table.insert(filter, character)
	end
	local dragged = ctx.drag.getObject()
	if dragged then
		table.insert(filter, dragged)
	end
	raycastParams.FilterDescendantsInstances = filter
end

----------------------------------------------------------------------
-- Targeting.
----------------------------------------------------------------------

local function clearTarget()
	target = nil
	targetKind = "None"
	highlight.Adornee = nil
	highlight.Enabled = false
	setPrompt(nil)
end

local function setTarget(object: Instance, kind: string)
	target = object
	targetKind = kind
	highlight.Adornee = object
	highlight.Enabled = true
	if kind == "Weapon" then
		highlight.OutlineColor = Color3.fromRGB(255, 120, 120)
		setPrompt(string.format("[%s] Equip", Config.Input.equipKey.Name))
	else
		highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
		setPrompt("Hold Left-Click to Grab  •  Release to Drop")
	end
end

local function updateTargeting()
	-- Only target while truly empty-handed (no hold, not dragging).
	if currentKind ~= "None" or ctx.drag.isDragging() then
		if target then
			clearTarget()
		end
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	refreshRaycastFilter()

	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector * DragCfg.maxPickupDistance
	local result = Workspace:Raycast(origin, direction, raycastParams)

	local found: Instance? = nil
	local foundKind = "None"
	if result then
		local object = ItemRegistry.resolve(result.Instance)
		if object then
			local kind = ItemRegistry.classify(object)
			-- Skip props already held by someone; weapons already equipped.
			local heldBy = object:GetAttribute(Config.HeldByAttribute)
			if heldBy == nil then
				if kind == "Weapon" then
					found = object
					foundKind = "Weapon"
				elseif kind == "Prop" and ItemRegistry.isDraggable(object) then
					found = object
					foundKind = "Prop"
				end
			end
		end
	end

	if found ~= target then
		if found then
			setTarget(found, foundKind)
		else
			clearTarget()
		end
	end
end

----------------------------------------------------------------------
-- Input.
----------------------------------------------------------------------

local function isEquipInput(input: InputObject): boolean
	return input.KeyCode == Config.Input.equipKey or input.KeyCode == Config.Input.gamepadEquipKey
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	-- E to equip a weapon we're looking at.
	if isEquipInput(input) then
		if currentKind == "None" and target and targetKind == "Weapon" then
			ctx.remotes.EquipRequest:FireServer(target)
		end
		return
	end

	-- G to put a held gun away.
	if input.KeyCode == Config.Input.unequipKey then
		if currentKind == "Weapon" then
			ctx.remotes.UnequipRequest:FireServer()
		end
		return
	end

	-- Left-click to grab a prop — only when empty-handed (a gun owns left-click).
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if currentKind == "None" and not ctx.drag.isDragging() and target and targetKind == "Prop" then
			ctx.drag.beginDrag(target)
			clearTarget()
		end
	end
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function onCharacter(char: Model)
	character = char
	clearTarget()
	refreshRaycastFilter()
end

function InteractionController.start(context: Context)
	ctx = context

	ctx.remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		currentKind = kind or "None"
		if currentKind ~= "None" then
			clearTarget()
		end
	end)
	-- An equip that failed/cleared returns us to empty-handed targeting.
	ctx.remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean)
		if not ok then
			-- Server rejected; HoldStateChanged remains authoritative otherwise.
		end
	end)

	UserInputService.InputBegan:Connect(onInputBegan)

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
	refreshRaycastFilter()

	RunService:BindToRenderStep("InteractionTargeting", Enum.RenderPriority.Camera.Value + 1, updateTargeting)
end

return InteractionController
