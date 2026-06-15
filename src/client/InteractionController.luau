--!strict
-- Module: InteractionController  (client-side)
-- Per-frame raycast targeting, highlight, reticle, and interaction prompt.
-- Ported from consensus FirstPersonPickupClient + new routing by ItemRegistry.
-- Blueprint §11.2.
--
-- Routing logic:
--   Weapon → show "E to Equip" prompt; E key → EquipRequest
--   Prop   → show "Hold [LMB] to Drag" prompt; LMB while empty-handed → DragController.beginDrag
--   None   → clear

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- -------------------------------------------------------------------------
-- Types
-- -------------------------------------------------------------------------

type DragControllerInterface = {
	beginDrag: (self: any, prop: Instance) -> (),
	endDrag:   (self: any) -> (),
	isDragging: (self: any) -> boolean,
}

type RemotesInterface = {
	EquipRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
}

-- -------------------------------------------------------------------------
-- UI: reticle, highlight, prompt
-- -------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "CombatSystemUI"
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

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "AmmoLabel"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.fromScale(0.95, 0.95)
ammoLabel.Size = UDim2.fromOffset(180, 36)
ammoLabel.BackgroundTransparency = 1
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextSize = 22
ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ammoLabel.TextStrokeTransparency = 0.5
ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
ammoLabel.Text = ""
ammoLabel.Visible = false
ammoLabel.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "InteractionHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
highlight.Enabled = false
highlight.Adornee = nil
highlight.Parent = gui

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

local currentHoldKind: "Weapon" | "Prop" | "None" = "None"
local targetObject: Instance? = nil
local character: Model? = player.Character

-- -------------------------------------------------------------------------
-- Raycast
-- -------------------------------------------------------------------------

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter(dragController: DragControllerInterface?)
	local filter: { Instance } = {}
	if character then table.insert(filter, character) end
	-- Exclude the held prop so the crosshair doesn't hit it.
	if dragController and dragController:isDragging() then
		-- DragController exposes heldObject for filter purposes.
		local dc = dragController :: any
		if dc.heldObject then
			table.insert(filter, dc.heldObject)
		end
	end
	raycastParams.FilterDescendantsInstances = filter
end

-- -------------------------------------------------------------------------
-- Prompt helpers
-- -------------------------------------------------------------------------

local function setPrompt(text: string?)
	if text and text ~= "" then
		prompt.Text = text
		prompt.Visible = true
	else
		prompt.Visible = false
	end
end

-- Expose to WeaponController for ammo HUD updates.
-- Pass nil to hide the display (e.g. on unequip).
local function setAmmoDisplay(ammo: number?, maxAmmo: number?)
	if ammo ~= nil and maxAmmo ~= nil then
		ammoLabel.Text = tostring(ammo) .. " / " .. tostring(maxAmmo)
		ammoLabel.Visible = true
	else
		ammoLabel.Visible = false
	end
end

-- -------------------------------------------------------------------------
-- Targeting
-- -------------------------------------------------------------------------

local function setTarget(object: Instance?, dragController: DragControllerInterface?)
	targetObject = object
	if object then
		highlight.Adornee = object
		highlight.Enabled = true
		local kind = ItemRegistry.classify(object)
		if kind == "Weapon" then
			setPrompt("[E] Equip")
		elseif kind == "Prop" then
			if currentHoldKind == "None" then
				setPrompt("[LMB] Drag")
			else
				setPrompt(nil)
			end
		else
			setPrompt(nil)
		end
	else
		highlight.Adornee = nil
		highlight.Enabled = false
		if currentHoldKind == "None" then
			setPrompt(nil)
		end
	end
end

local function updateTargeting(cam: Camera, dragController: DragControllerInterface)
	-- Don't scan while dragging — the prop is already held.
	if dragController:isDragging() then
		if targetObject then setTarget(nil, dragController) end
		return
	end

	refreshRaycastFilter(dragController)
	local origin = cam.CFrame.Position
	local dir = cam.CFrame.LookVector * Config.Drag.maxPickupDistance
	local result = Workspace:Raycast(origin, dir, raycastParams)

	local found: Instance? = nil
	if result then
		local node: Instance? = result.Instance
		while node and node ~= Workspace do
			local kind = ItemRegistry.classify(node :: Instance)
			if kind ~= "None" then
				-- Skip objects already held by someone.
				if (node :: Instance):GetAttribute(Config.Detection.heldByAttribute) == nil then
					found = node :: Instance
				end
				break
			end
			node = (node :: Instance).Parent
		end
	end

	if found ~= targetObject then
		setTarget(found, dragController)
	end
end

-- -------------------------------------------------------------------------
-- InteractionController class
-- -------------------------------------------------------------------------

local InteractionController = {}
InteractionController.__index = InteractionController

function InteractionController.new(remotes: RemotesInterface, dragController: DragControllerInterface)
	local self = setmetatable({}, InteractionController)
	self.remotes = remotes
	self.dragController = dragController
	self._connections = {}
	self.setAmmoDisplay = setAmmoDisplay
	return self
end

function InteractionController:start()
	local dc = self.dragController

	-- Listen for hold-state changes from server.
	table.insert(self._connections,
		self.remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
			currentHoldKind = kind :: any
			-- Clear targeting prompt when we pick something up.
			if kind ~= "None" then
				setTarget(nil, dc)
				setPrompt(nil)
			end
		end)
	)

	-- E key → equip weapon.
	table.insert(self._connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then return end
			if input.KeyCode == Enum.KeyCode.E then
				local target = targetObject
				if target and ItemRegistry.classify(target) == "Weapon" and currentHoldKind == "None" then
					self.remotes.EquipRequest:FireServer(target)
				end
			end
		end)
	)

	-- LMB down → begin drag (only if no weapon equipped and looking at a draggable prop).
	table.insert(self._connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then return end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local target = targetObject
				if target and ItemRegistry.classify(target) == "Prop" and currentHoldKind == "None" then
					dc:beginDrag(target)
				end
			end
		end)
	)

	-- LMB up → end drag.
	table.insert(self._connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if dc:isDragging() then
					dc:endDrag()
				end
			end
		end)
	)

	-- Character lifecycle.
	table.insert(self._connections,
		player.CharacterAdded:Connect(function(char: Model)
			character = char
		end)
	)
	if player.Character then
		character = player.Character
	end

	-- Camera change guard.
	table.insert(self._connections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			camera = Workspace.CurrentCamera
		end)
	)

	-- Per-frame loop.
	RunService:BindToRenderStep(
		"InteractionControllerUpdate",
		Enum.RenderPriority.Camera.Value + 1,
		function()
			local cam = Workspace.CurrentCamera
			if not cam then return end
			updateTargeting(cam, dc)
		end
	)
end

function InteractionController:destroy()
	RunService:UnbindFromRenderStep("InteractionControllerUpdate")
	for _, c in self._connections do c:Disconnect() end
	self._connections = {}
end

return InteractionController
