--!strict
-- Module: ViewmodelController
-- First-person arms + gun viewmodel with sway and walk bob.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local ViewmodelController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local viewmodelRoot: Model? = nil
local muzzleAttachment: Attachment? = nil
local currentWeaponId: string? = nil
local visible = false

local swayOffset = Vector3.zero
local bobPhase = 0
local lastCameraLook: Vector3? = nil

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function findAssetsFolder(): Instance?
	local assets = ReplicatedStorage:FindFirstChild(Config.Viewmodel.assetsFolderName)
	if assets then
		return assets
	end
	local folder = Instance.new("Folder")
	folder.Name = Config.Viewmodel.assetsFolderName
	folder.Parent = ReplicatedStorage
	return folder
end

local function findViewmodelsFolder(): Instance?
	local assets = findAssetsFolder()
	local viewmodels = assets:FindFirstChild(Config.Viewmodel.viewmodelsFolderName)
	if viewmodels then
		return viewmodels
	end
	local folder = Instance.new("Folder")
	folder.Name = Config.Viewmodel.viewmodelsFolderName
	folder.Parent = assets
	return folder
end

local function createFallbackViewmodel(weaponId: string): Model
	local def = ItemRegistry.getWeaponDef(weaponId)
	local displayName = if def then def.displayName else "Weapon"

	local model = Instance.new("Model")
	model.Name = if def then def.viewmodelName else "FallbackViewmodel"

	local armColor = Color3.fromRGB(210, 180, 140)
	local gunColor = Color3.fromRGB(45, 45, 50)

	local rightArm = Instance.new("Part")
	rightArm.Name = "RightArm"
	rightArm.Size = Vector3.new(0.35, 1.1, 0.35)
	rightArm.Color = armColor
	rightArm.Material = Enum.Material.SmoothPlastic
	rightArm.CanCollide = false
	rightArm.CanQuery = false
	rightArm.CanTouch = false
	rightArm.Anchored = true
	rightArm.CFrame = CFrame.new(0.35, -0.35, -0.9)
	rightArm.Parent = model

	local leftArm = Instance.new("Part")
	leftArm.Name = "LeftArm"
	leftArm.Size = Vector3.new(0.35, 1.0, 0.35)
	leftArm.Color = armColor
	leftArm.Material = Enum.Material.SmoothPlastic
	leftArm.CanCollide = false
	leftArm.CanQuery = false
	leftArm.CanTouch = false
	leftArm.Anchored = true
	leftArm.CFrame = CFrame.new(-0.15, -0.4, -0.75)
	leftArm.Parent = model

	local gunBody = Instance.new("Part")
	gunBody.Name = "GunBody"
	gunBody.Size = Vector3.new(0.2, 0.25, 0.9)
	gunBody.Color = gunColor
	gunBody.Material = Enum.Material.Metal
	gunBody.CanCollide = false
	gunBody.CanQuery = false
	gunBody.CanTouch = false
	gunBody.Anchored = true
	gunBody.CFrame = CFrame.new(0.2, -0.25, -1.1)
	gunBody.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.08, 0.08, 0.35)
	barrel.Color = gunColor
	barrel.Material = Enum.Material.Metal
	barrel.CanCollide = false
	barrel.CanQuery = false
	barrel.CanTouch = false
	barrel.Anchored = true
	barrel.CFrame = gunBody.CFrame * CFrame.new(0, 0.02, -0.55)
	barrel.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -barrel.Size.Z * 0.5)
	muzzle.Parent = barrel

	local label = Instance.new("BillboardGui")
	label.Name = "Label"
	label.Size = UDim2.fromOffset(120, 24)
	label.StudsOffset = Vector3.new(0, 0.5, 0)
	label.AlwaysOnTop = true
	label.Parent = gunBody
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = displayName
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label

	model.PrimaryPart = gunBody
	return model
end

local function cloneViewmodel(weaponId: string): Model
	local def = ItemRegistry.getWeaponDef(weaponId)
	local viewmodelName = if def then def.viewmodelName else "FallbackViewmodel"
	local viewmodels = findViewmodelsFolder()
	local template = viewmodels:FindFirstChild(viewmodelName)

	local model: Model
	if template and template:IsA("Model") then
		model = template:Clone()
	else
		model = createFallbackViewmodel(weaponId)
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
		end
	end

	model.Name = "LocalViewmodel"
	return model
end

local function findMuzzle(model: Model): Attachment?
	local named = model:FindFirstChild("Muzzle", true)
	if named and named:IsA("Attachment") then
		return named
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and string.find(string.lower(descendant.Name), "muzzle") then
			return descendant
		end
	end
	local gunPart = model:FindFirstChild("GunBody") or model.PrimaryPart
	if gunPart and gunPart:IsA("BasePart") then
		local muzzle = Instance.new("Attachment")
		muzzle.Name = "Muzzle"
		muzzle.Position = Vector3.new(0, 0, -gunPart.Size.Z * 0.5)
		muzzle.Parent = gunPart
		return muzzle
	end
	return nil
end

local function hideViewmodel()
	visible = false
	currentWeaponId = nil
	muzzleAttachment = nil
	if viewmodelRoot then
		viewmodelRoot:Destroy()
		viewmodelRoot = nil
	end
end

local function showViewmodel(weaponId: string)
	hideViewmodel()
	currentWeaponId = weaponId
	viewmodelRoot = cloneViewmodel(weaponId)
	viewmodelRoot.Parent = Workspace.CurrentCamera or Workspace
	muzzleAttachment = findMuzzle(viewmodelRoot)
	visible = true
	swayOffset = Vector3.zero
	bobPhase = 0
end

local function springTowards(current: Vector3, target: Vector3, dt: number): Vector3
	local frequency = Config.Viewmodel.springFrequency
	local damping = Config.Viewmodel.springDamping
	local omega = frequency * 2 * math.pi
	local expTerm = math.exp(-damping * omega * dt)
	return target + (current - target) * expTerm
end

local function updateViewmodel(dt: number)
	if not visible or not viewmodelRoot then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local speed = if humanoid then humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed else 0

	local look = cam.CFrame.LookVector
	local lookDelta = if lastCameraLook then look - lastCameraLook else Vector3.zero
	lastCameraLook = look

	local swayTarget = Vector3.new(
		-lookDelta.X * Config.Viewmodel.swayAmount * 200,
		-lookDelta.Y * Config.Viewmodel.swayAmount * 200,
		0
	)
	swayOffset = springTowards(swayOffset, swayTarget, dt)

	if speed > 0.5 then
		bobPhase += dt * Config.Viewmodel.bobSpeed * (speed / 16)
	end
	local bobY = math.sin(bobPhase) * Config.Viewmodel.bobAmount * (speed / 16)
	local bobX = math.cos(bobPhase * 0.5) * Config.Viewmodel.bobAmount * 0.5 * (speed / 16)

	local base = cam.CFrame * Config.Viewmodel.baseOffsetCFrame
	local offset = CFrame.new(swayOffset.X + bobX, swayOffset.Y + bobY, swayOffset.Z)
	viewmodelRoot:PivotTo(base * offset)
end

function ViewmodelController.getMuzzlePosition(): Vector3
	if muzzleAttachment and muzzleAttachment.Parent and muzzleAttachment.Parent:IsA("BasePart") then
		return muzzleAttachment.WorldPosition
	end
	local cam = getCamera()
	if cam then
		return (cam.CFrame * Config.Viewmodel.baseOffsetCFrame * CFrame.new(0, 0, -1.2)).Position
	end
	return Vector3.zero
end

function ViewmodelController.playFireKick()
	if not viewmodelRoot or not viewmodelRoot.PrimaryPart then
		return
	end
	local primary = viewmodelRoot.PrimaryPart
	local original = primary.CFrame
	primary.CFrame = original * CFrame.new(0, 0, 0.08)
	task.delay(0.05, function()
		if primary.Parent then
			primary.CFrame = original
		end
	end)
end

function ViewmodelController.onEquip(weaponId: string)
	showViewmodel(weaponId)
end

function ViewmodelController.onUnequip()
	hideViewmodel()
end

function ViewmodelController.onHoldStateChanged(kind: string, newWeaponId: string?)
	if kind == "Weapon" and newWeaponId then
		showViewmodel(newWeaponId)
	else
		hideViewmodel()
	end
end

function ViewmodelController.start()
	if Config.Viewmodel.forceFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera and viewmodelRoot then
			viewmodelRoot.Parent = Workspace.CurrentCamera
		end
	end)

	RunService:BindToRenderStep("ViewmodelControllerUpdate", Enum.RenderPriority.Camera.Value + 3, updateViewmodel)
end

return ViewmodelController
