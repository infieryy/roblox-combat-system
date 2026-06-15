--!strict
-- Module: client/ViewmodelController.luau

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)

local ViewmodelController = {}

type ViewmodelState = "Empty" | "Weapon"

local player = Players.LocalPlayer
local state: ViewmodelState = "Empty"
local currentWeaponId: string? = nil
local viewmodelRoot: Model? = nil
local muzzleAttachment: Attachment? = nil

local swayOffset = CFrame.identity
local bobPhase = 0
local fireKick = 0
local lastLookVector = Vector3.new(0, 0, -1)

local remotes: {
	EquipResult: RemoteEvent,
	HoldStateChanged: RemoteEvent,
}? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function destroyViewmodel()
	if viewmodelRoot then
		viewmodelRoot:Destroy()
	end
	viewmodelRoot = nil
	muzzleAttachment = nil
end

local function createPart(name: string, size: Vector3, color: Color3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function buildFallbackViewmodel(weaponId: string): Model
	local def = ItemRegistry.getWeaponDef(weaponId)
	local model = Instance.new("Model")
	model.Name = "FallbackViewmodel"

	local rightArm = createPart("RightArm", Vector3.new(0.35, 1.1, 0.35), Color3.fromRGB(255, 204, 153), model)
	rightArm.CFrame = CFrame.new(0.35, -0.35, -0.2)

	local leftArm = createPart("LeftArm", Vector3.new(0.35, 1.0, 0.35), Color3.fromRGB(255, 204, 153), model)
	leftArm.CFrame = CFrame.new(-0.15, -0.3, -0.55) * CFrame.Angles(0, 0.35, 0)

	local gunBody = createPart("GunBody", Vector3.new(0.18, 0.22, 0.9), Color3.fromRGB(45, 45, 45), model)
	gunBody.CFrame = CFrame.new(0.2, -0.15, -0.75)

	local barrel = createPart("Barrel", Vector3.new(0.08, 0.08, 0.45), Color3.fromRGB(25, 25, 25), model)
	barrel.CFrame = gunBody.CFrame * CFrame.new(0, 0.02, -0.65)

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -barrel.Size.Z * 0.5)
	muzzle.Parent = barrel
	muzzleAttachment = muzzle

	if def then
		local label = Instance.new("BillboardGui")
		label.Size = UDim2.fromOffset(120, 24)
		label.AlwaysOnTop = true
		label.Parent = gunBody
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = def.displayName
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextScaled = true
		text.Parent = label
	end

	model.PrimaryPart = gunBody
	return model
end

local function cloneStudioViewmodel(viewmodelName: string): Model?
	local folder = ReplicatedStorage:FindFirstChild(Config.ViewmodelsFolderName)
	if not folder then
		return nil
	end
	local template = folder:FindFirstChild(viewmodelName)
	if not template or not template:IsA("Model") then
		return nil
	end
	local clone = template:Clone()
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.Anchored = true
			part.CastShadow = false
		end
	end
	local muzzle = clone:FindFirstChild("Muzzle", true)
	if muzzle and muzzle:IsA("Attachment") then
		muzzleAttachment = muzzle
	end
	return clone
end

local function showWeapon(weaponId: string)
	destroyViewmodel()
	currentWeaponId = weaponId
	state = "Weapon"

	local def = ItemRegistry.getWeaponDef(weaponId)
	local viewmodelName = if def then def.viewmodelName else weaponId
	local model = cloneStudioViewmodel(viewmodelName)
	if not model then
		model = buildFallbackViewmodel(weaponId)
	end

	local camera = getCamera()
	if camera then
		model.Parent = camera
	else
		model.Parent = Workspace
	end
	viewmodelRoot = model
end

local function hideWeapon()
	state = "Empty"
	currentWeaponId = nil
	destroyViewmodel()
	swayOffset = CFrame.identity
	bobPhase = 0
	fireKick = 0
end

function ViewmodelController.getMuzzlePosition(): Vector3
	if muzzleAttachment and muzzleAttachment.Parent and muzzleAttachment.Parent:IsA("BasePart") then
		return muzzleAttachment.WorldPosition
	end
	local camera = getCamera()
	if camera then
		return (camera.CFrame * Config.Viewmodel.baseOffsetCFrame * CFrame.new(0, 0, -1.5)).Position
	end
	return Vector3.zero
end

function ViewmodelController.playFireKick()
	fireKick = Config.Viewmodel.fireKickAmount
end

function ViewmodelController.isWeaponVisible(): boolean
	return state == "Weapon"
end

function ViewmodelController.getWeaponId(): string?
	return currentWeaponId
end

local function updateViewmodelTransform(dt: number, camera: Camera)
	if not viewmodelRoot or not viewmodelRoot.PrimaryPart then
		return
	end

	local vm = Config.Viewmodel
	local look = camera.CFrame.LookVector
	local lookDelta = look - lastLookVector
	lastLookVector = look

	local targetSway = CFrame.Angles(-lookDelta.Y * vm.swayAmount * 40, -lookDelta.X * vm.swayAmount * 40, 0)
	local alpha = math.clamp(dt * vm.swaySpeed, 0, 1)
	swayOffset = swayOffset:Lerp(targetSway, alpha)

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local speed = if humanoid then humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed else 0
	bobPhase += dt * vm.bobSpeed * math.clamp(speed / 16, 0, 1.5)
	local bob = CFrame.new(
		math.sin(bobPhase) * vm.bobAmount,
		math.abs(math.cos(bobPhase)) * vm.bobAmount * 0.5,
		0
	)

	fireKick = math.max(0, fireKick - dt * vm.fireKickRecovery)
	local kick = CFrame.new(0, 0, fireKick)

	local base = camera.CFrame * Config.Viewmodel.baseOffsetCFrame * swayOffset * bob * kick
	viewmodelRoot:PivotTo(base)
end

function ViewmodelController.configure(remoteTable: typeof(remotes))
	remotes = remoteTable
	if not remotes then
		return
	end

	remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, _ammo: number?)
		if ok and weaponId then
			showWeapon(weaponId)
		else
			hideWeapon()
		end
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind == "Weapon" and weaponId then
			showWeapon(weaponId)
		elseif kind == "None" then
			hideWeapon()
		elseif kind == "Prop" then
			hideWeapon()
		end
	end)
end

function ViewmodelController.start()
	player.CameraMode = Enum.CameraMode.LockFirstPerson

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local camera = getCamera()
		if camera and viewmodelRoot then
			viewmodelRoot.Parent = camera
		end
	end)

	local camera = getCamera()
	if camera then
		lastLookVector = camera.CFrame.LookVector
	end

	RunService:BindToRenderStep("ItemSystemViewmodel", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local cam = getCamera()
		if cam and state == "Weapon" then
			updateViewmodelTransform(dt, cam)
		end
	end)
end

return ViewmodelController
