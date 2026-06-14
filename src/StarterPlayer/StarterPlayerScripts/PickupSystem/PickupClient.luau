--!strict
--[[
	PickupClient
	Frame-perfect first-person raycast targeting, E to pick up / drop,
	and R + mouse inspection rotation while holding.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PickupConfig = require(ReplicatedStorage.Shared.PickupConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PhysicsUtility = require(ReplicatedStorage.PickupSystem.PhysicsUtility)

type InteractableRoot = PhysicsUtility.InteractableRoot

local PickupClient = {}

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local currentTarget: InteractableRoot? = nil
local heldObject: InteractableRoot? = nil
local holdTarget: BasePart? = nil

local isRotating = false
local holdRotation = CFrame.identity
local heldWorldRotation: CFrame = CFrame.identity

local highlight: Highlight? = nil
local raycastParams: RaycastParams = PhysicsUtility.buildRaycastParams(nil)

local function refreshRaycastFilter(): ()
	raycastParams = PhysicsUtility.buildRaycastParams(player.Character)
end

local function getOrCreateHighlight(): Highlight
	if highlight and highlight.Parent then
		return highlight
	end

	local newHighlight = Instance.new("Highlight")
	newHighlight.Name = "PickupHighlight"
	newHighlight.FillTransparency = 0.85
	newHighlight.OutlineTransparency = 0
	newHighlight.OutlineColor = Color3.fromRGB(255, 220, 120)
	newHighlight.FillColor = Color3.fromRGB(255, 200, 80)
	newHighlight.Enabled = false
	newHighlight.Parent = workspace
	highlight = newHighlight
	return newHighlight
end

local function setHighlightTarget(target: InteractableRoot?): ()
	local activeHighlight = getOrCreateHighlight()
	if target then
		activeHighlight.Adornee = target
		activeHighlight.Enabled = true
	else
		activeHighlight.Adornee = nil
		activeHighlight.Enabled = false
	end
end

local function findLocalHoldTarget(): BasePart?
	for _, child in workspace:GetChildren() do
		if
			child:IsA("BasePart")
			and child.Name == PickupConfig.HOLD_TARGET_NAME
			and child:GetAttribute("OwnerUserId") == player.UserId
		then
			return child
		end
	end
	return nil
end

local function performCameraRaycast(): RaycastResult?
	if not camera then
		return nil
	end

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * PickupConfig.MAX_PICKUP_DISTANCE
	return workspace:Raycast(origin, direction, raycastParams)
end

local function updateTargeting(): ()
	if heldObject then
		currentTarget = nil
		setHighlightTarget(nil)
		return
	end

	local result = performCameraRaycast()
	if not result then
		currentTarget = nil
		setHighlightTarget(nil)
		return
	end

	local root = PhysicsUtility.getInteractableRoot(result.Instance)
	currentTarget = root
	setHighlightTarget(root)
end

local function getHoldOffsetCFrame(): CFrame
	return CFrame.new(0, PickupConfig.HOLD_VERTICAL_OFFSET, -PickupConfig.HOLD_DISTANCE)
end

local function updateHoldTargetTransform(): ()
	if not holdTarget or not camera then
		return
	end

	local holdPosition = (camera.CFrame * getHoldOffsetCFrame()).Position

	if isRotating then
		local cameraHold = camera.CFrame * getHoldOffsetCFrame()
		holdTarget.CFrame = CFrame.new(cameraHold.Position) * cameraHold.Rotation * holdRotation
		heldWorldRotation = holdTarget.CFrame.Rotation
	else
		holdTarget.CFrame = CFrame.new(holdPosition) * heldWorldRotation
	end
end

local function requestPickup(): ()
	if heldObject then
		Remotes.DropRequest:FireServer()
		return
	end

	if not currentTarget then
		return
	end

	local result = performCameraRaycast()
	if not result then
		return
	end

	local root = PhysicsUtility.getInteractableRoot(result.Instance)
	if root ~= currentTarget then
		return
	end

	Remotes.PickupRequest:FireServer(currentTarget, result.Position)
end

local function onPickupResult(success: boolean, object: InteractableRoot?): ()
	if not success or not object then
		heldObject = nil
		holdTarget = nil
		player:SetAttribute("HoldingPickup", false)
		return
	end

	heldObject = object
	holdTarget = findLocalHoldTarget()
	holdRotation = CFrame.identity
	heldWorldRotation = PhysicsUtility.getHoldAnchorCFrame(object).Rotation
	player:SetAttribute("HoldingPickup", true)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end

	if input.KeyCode == PickupConfig.KEY_PICKUP and input.UserInputState == Enum.UserInputState.Begin then
		requestPickup()
	elseif input.KeyCode == PickupConfig.KEY_ROTATE and input.UserInputState == Enum.UserInputState.Begin then
		if heldObject and camera then
			isRotating = true
			local cameraHold = camera.CFrame * getHoldOffsetCFrame()
			holdRotation = cameraHold.Rotation:Inverse() * heldWorldRotation
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean): ()
	if input.KeyCode == PickupConfig.KEY_ROTATE then
		isRotating = false
		if heldObject then
			heldWorldRotation = if holdTarget then holdTarget.CFrame.Rotation else heldWorldRotation
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end
end

local function onInputChanged(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed or not isRotating or not heldObject then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Delta
		holdRotation = holdRotation * CFrame.Angles(
			delta.Y * PickupConfig.ROTATION_SENSITIVITY,
			-delta.X * PickupConfig.ROTATION_SENSITIVITY,
			0
		)
	end
end

local function onRenderStep(_deltaTime: number): ()
	if not camera then
		camera = workspace.CurrentCamera
	end

	updateTargeting()

	if heldObject then
		if not holdTarget or not holdTarget.Parent then
			holdTarget = findLocalHoldTarget()
		end
		updateHoldTargetTransform()
	end
end

local function onCharacterAdded(character: Model): ()
	refreshRaycastFilter()
	character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			refreshRaycastFilter()
		end
	end)
end

function PickupClient.init(): ()
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	player:GetAttributeChangedSignal("HoldingPickup"):Connect(function()
		if player:GetAttribute("HoldingPickup") == false then
			heldObject = nil
			holdTarget = nil
			isRotating = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)

	Remotes.PickupResult.OnClientEvent:Connect(onPickupResult)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.InputChanged:Connect(onInputChanged)

	RunService:BindToRenderStep("PickupClient", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

return PickupClient
