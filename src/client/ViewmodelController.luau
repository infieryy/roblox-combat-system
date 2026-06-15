--!strict
-- Module: ViewmodelController
-- First-person arms + gun viewmodel with sway and walk bob.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local RemotesClient = require(script.Parent.RemotesClient)

local ViewmodelController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local viewmodelRoot: Model? = nil
local muzzleAttachment: Attachment? = nil
local equippedWeaponId: string? = nil
local visible = false
local bobPhase = 0
local swayOffset = Vector3.zero
local swayVelocity = Vector3.zero
local fireKick = 0
local lastCameraRotation = CFrame.identity

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function findMuzzle(model: Instance): Attachment?
	local named = model:FindFirstChild("Muzzle", true)
	if named and named:IsA("Attachment") then
		return named
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and string.find(string.lower(descendant.Name), "muzzle") then
			return descendant
		end
	end
	return nil
end

local function createPlaceholderViewmodel(weaponId: string): Model
	local model = Instance.new("Model")
	model.Name = "Viewmodel_" .. weaponId

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Anchored = true
	root.Parent = model
	model.PrimaryPart = root

	local rightArm = Instance.new("Part")
	rightArm.Name = "RightArm"
	rightArm.Size = Vector3.new(0.35, 1.1, 0.35)
	rightArm.Color = Color3.fromRGB(180, 140, 110)
	rightArm.Material = Enum.Material.SmoothPlastic
	rightArm.CanCollide = false
	rightArm.CanQuery = false
	rightArm.CanTouch = false
	rightArm.Anchored = true
	rightArm.CFrame = root.CFrame * CFrame.new(0.25, -0.35, -0.35)
	rightArm.Parent = model

	local leftArm = Instance.new("Part")
	leftArm.Name = "LeftArm"
	leftArm.Size = Vector3.new(0.35, 1.0, 0.35)
	leftArm.Color = Color3.fromRGB(180, 140, 110)
	leftArm.Material = Enum.Material.SmoothPlastic
	leftArm.CanCollide = false
	leftArm.CanQuery = false
	leftArm.CanTouch = false
	leftArm.Anchored = true
	leftArm.CFrame = root.CFrame * CFrame.new(-0.2, -0.3, -0.55)
	leftArm.Parent = model

	local gunBody = Instance.new("Part")
	gunBody.Name = "GunBody"
	if string.find(weaponId, "rifle") then
		gunBody.Size = Vector3.new(0.25, 0.35, 1.4)
	else
		gunBody.Size = Vector3.new(0.22, 0.3, 0.75)
	end
	gunBody.Color = Color3.fromRGB(45, 45, 50)
	gunBody.Material = Enum.Material.Metal
	gunBody.CanCollide = false
	gunBody.CanQuery = false
	gunBody.CanTouch = false
	gunBody.Anchored = true
	gunBody.CFrame = root.CFrame * CFrame.new(0.15, -0.15, -0.75)
	gunBody.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.12, 0.12, if string.find(weaponId, "rifle") then 0.8 else 0.35)
	barrel.Color = Color3.fromRGB(25, 25, 28)
	barrel.Material = Enum.Material.Metal
	barrel.CanCollide = false
	barrel.CanQuery = false
	barrel.CanTouch = false
	barrel.Anchored = true
	barrel.CFrame = gunBody.CFrame * CFrame.new(0, 0.02, -((gunBody.Size.Z * 0.5) + (barrel.Size.Z * 0.5)))
	barrel.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -barrel.Size.Z * 0.5)
	muzzle.Parent = barrel

	return model
end

local function loadViewmodelAsset(viewmodelName: string): Model?
	local folder = ReplicatedStorage:FindFirstChild(Config.Viewmodel.viewmodelsFolderName)
	if folder then
		local template = folder:FindFirstChild(viewmodelName)
		if template and template:IsA("Model") then
			return template:Clone()
		end
	end
	return nil
end

local function destroyViewmodel()
	if viewmodelRoot then
		viewmodelRoot:Destroy()
		viewmodelRoot = nil
	end
	muzzleAttachment = nil
	visible = false
	equippedWeaponId = nil
end

local function showViewmodel(weaponId: string)
	destroyViewmodel()

	local def = ItemRegistry.getWeaponDef(weaponId)
	local viewmodelName = if def then def.viewmodelName else weaponId

	local model = loadViewmodelAsset(viewmodelName)
	if not model then
		model = createPlaceholderViewmodel(weaponId)
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = 0
			part.CastShadow = false
		end
	end

	model.Parent = Workspace
	viewmodelRoot = model
	muzzleAttachment = findMuzzle(model)
	equippedWeaponId = weaponId
	visible = true
	bobPhase = 0
	swayOffset = Vector3.zero
	swayVelocity = Vector3.zero
	fireKick = 0

	local cam = getCamera()
	if cam then
		lastCameraRotation = cam.CFrame.Rotation
	end
end

local function hideViewmodel()
	destroyViewmodel()
end

local function springStep(current: Vector3, velocity: Vector3, target: Vector3, dt: number): (Vector3, Vector3)
	local frequency = Config.Viewmodel.springFrequency
	local damping = Config.Viewmodel.springDamping
	local omega = frequency * 2 * math.pi
	local x = current - target
	local f = omega * omega * (-x) - 2 * damping * omega * velocity
	local newVelocity = velocity + f * dt
	local newCurrent = current + newVelocity * dt
	return newCurrent, newVelocity
end

local function getWalkSpeed(): number
	local character = player.Character
	if not character then
		return 0
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return 0
	end
	return humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
end

local function updateViewmodelTransform(dt: number)
	if not visible or not viewmodelRoot or not viewmodelRoot.PrimaryPart then
		return
	end

	local cam = getCamera()
	if not cam then
		return
	end

	local vm = Config.Viewmodel
	local camRotation = cam.CFrame.Rotation
	local deltaRotation = lastCameraRotation:ToObjectSpace(camRotation)
	lastCameraRotation = camRotation

	local _, yaw, pitch = deltaRotation:ToEulerAnglesYXZ()
	local swayTarget = Vector3.new(
		-pitch * vm.swayAmount * vm.swaySpeed,
		-yaw * vm.swayAmount * vm.swaySpeed,
		0
	)
	swayOffset, swayVelocity = springStep(swayOffset, swayVelocity, swayTarget, dt)

	local speed = getWalkSpeed()
	if speed > 0.5 then
		bobPhase += dt * vm.bobSpeed * (speed / 16)
	else
		bobPhase *= 0.9
	end

	local bobOffset = Vector3.new(
		math.sin(bobPhase) * vm.bobAmount,
		math.abs(math.cos(bobPhase * 2)) * vm.bobAmount * 0.5,
		0
	)

	fireKick = math.max(0, fireKick - dt * vm.fireKickRecovery)

	local kickOffset = Vector3.new(0, 0, fireKick)
	local offset = vm.baseOffsetCFrame * CFrame.new(swayOffset + bobOffset + kickOffset)
	viewmodelRoot:PivotTo(cam.CFrame * offset)
end

function ViewmodelController.getMuzzlePosition(): Vector3
	if muzzleAttachment and muzzleAttachment.Parent and muzzleAttachment.Parent:IsA("BasePart") then
		return muzzleAttachment.WorldPosition
	end
	local cam = getCamera()
	if cam then
		return (cam.CFrame * Config.Viewmodel.baseOffsetCFrame * CFrame.new(0, 0, -1.5)).Position
	end
	return Vector3.zero
end

function ViewmodelController.playFireKick()
	fireKick = Config.Viewmodel.fireKickAmount
end

function ViewmodelController.isVisible(): boolean
	return visible
end

function ViewmodelController.getEquippedWeaponId(): string?
	return equippedWeaponId
end

function ViewmodelController.onRenderStep(dt: number)
	updateViewmodelTransform(dt)
end

function ViewmodelController.start(remoteTable: RemotesClient.RemotesClientTable)
	player.CameraMode = Enum.CameraMode.LockFirstPerson

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?)
		if ok and weaponId then
			showViewmodel(weaponId)
		else
			hideViewmodel()
		end
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind == "Weapon" and weaponId then
			showViewmodel(weaponId)
		else
			hideViewmodel()
		end
	end)

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera then
			camera = Workspace.CurrentCamera
		end
	end)
end

return ViewmodelController
