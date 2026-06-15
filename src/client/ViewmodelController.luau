--!strict
-- Module: ViewmodelController
-- First-person arms + weapon viewmodel with sway and walk bob.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)

type Remotes = typeof(require(script.Parent.RemotesClient).waitForRemotes())

local ViewmodelController = {}

local remotes: Remotes? = nil
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local viewmodelRoot: Model? = nil
local muzzleAttachment: Attachment? = nil
local equippedWeaponId: string? = nil
local visible = false

local swayOffset = CFrame.identity
local bobOffset = CFrame.identity
local kickOffset = CFrame.identity
local lastCameraRotation = CFrame.identity

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function getHumanoid(): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function springToward(current: CFrame, target: CFrame, damping: number, frequency: number, dt: number): CFrame
	local alpha = 1 - math.exp(-frequency * dt)
	local position = current.Position:Lerp(target.Position, alpha * damping)
	local rotation = current.Rotation:Lerp(target.Rotation, alpha * damping)
	return CFrame.new(position) * rotation
end

local function findViewmodelTemplate(viewmodelName: string): Model?
	local assets = ReplicatedStorage:FindFirstChild(Config.Viewmodel.assetsFolderName)
	if assets then
		local template = assets:FindFirstChild(viewmodelName)
		if template and template:IsA("Model") then
			return template
		end
	end
	return nil
end

local function buildProceduralViewmodel(weaponId: string): Model
	local def = ItemRegistry.getWeaponDef(weaponId)
	local model = Instance.new("Model")
	model.Name = "Viewmodel_" .. weaponId

	local rightArm = Instance.new("Part")
	rightArm.Name = "RightArm"
	rightArm.Size = Vector3.new(0.35, 1.1, 0.35)
	rightArm.Color = Color3.fromRGB(255, 204, 153)
	rightArm.Material = Enum.Material.SmoothPlastic
	rightArm.CanCollide = false
	rightArm.CanQuery = false
	rightArm.CanTouch = false
	rightArm.Anchored = true
	rightArm.CFrame = CFrame.new(0.35, -0.35, -0.8)
	rightArm.Parent = model

	local leftArm = rightArm:Clone()
	leftArm.Name = "LeftArm"
	leftArm.CFrame = CFrame.new(-0.2, -0.25, -0.75)
	leftArm.Parent = model

	local gunBody = Instance.new("Part")
	gunBody.Name = "GunBody"
	gunBody.Size = if def and def.weaponId == "rifle_ar" then Vector3.new(0.25, 0.2, 1.4) else Vector3.new(0.2, 0.18, 0.75)
	gunBody.Color = Color3.fromRGB(45, 45, 50)
	gunBody.Material = Enum.Material.Metal
	gunBody.CanCollide = false
	gunBody.CanQuery = false
	gunBody.CanTouch = false
	gunBody.Anchored = true
	gunBody.CFrame = CFrame.new(0.15, -0.15, -1.0)
	gunBody.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.08, 0.08, if def and def.weaponId == "rifle_ar" then 0.6 else 0.35)
	barrel.Color = Color3.fromRGB(25, 25, 28)
	barrel.Material = Enum.Material.Metal
	barrel.CanCollide = false
	barrel.CanQuery = false
	barrel.CanTouch = false
	barrel.Anchored = true
	barrel.CFrame = gunBody.CFrame * CFrame.new(0, 0.02, -gunBody.Size.Z * 0.5 - barrel.Size.Z * 0.5)
	barrel.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -barrel.Size.Z * 0.5)
	muzzle.Parent = barrel

	model.PrimaryPart = gunBody
	return model
end

local function destroyViewmodel()
	if viewmodelRoot then
		viewmodelRoot:Destroy()
	end
	viewmodelRoot = nil
	muzzleAttachment = nil
	visible = false
	equippedWeaponId = nil
end

local function showViewmodel(weaponId: string)
	destroyViewmodel()

	local template = findViewmodelTemplate(weaponId)
	local model: Model
	if template then
		model = template:Clone()
		model.Name = "Viewmodel_" .. weaponId
	else
		model = buildProceduralViewmodel(weaponId)
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

	local muzzle = model:FindFirstChild("Muzzle", true)
	if muzzle and muzzle:IsA("Attachment") then
		muzzleAttachment = muzzle
	else
		local gunPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		if gunPart and gunPart:IsA("BasePart") then
			local attachment = Instance.new("Attachment")
			attachment.Name = "Muzzle"
			attachment.Position = Vector3.new(0, 0, -gunPart.Size.Z * 0.5)
			attachment.Parent = gunPart
			muzzleAttachment = attachment
		end
	end

	model.Parent = Workspace.CurrentCamera or Workspace
	viewmodelRoot = model
	equippedWeaponId = weaponId
	visible = true
	swayOffset = CFrame.identity
	bobOffset = CFrame.identity
	kickOffset = CFrame.identity
	local cam = getCamera()
	if cam then
		lastCameraRotation = cam.CFrame.Rotation
	end
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
	local vm = Config.Viewmodel
	kickOffset = kickOffset * CFrame.new(0, 0, vm.fireKickAmount)
end

function ViewmodelController.isWeaponVisible(): boolean
	return visible
end

function ViewmodelController.getEquippedWeaponId(): string?
	return equippedWeaponId
end

local function updateViewmodel(dt: number)
	if not visible or not viewmodelRoot then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end

	local vm = Config.Viewmodel
	local cameraRotation = cam.CFrame.Rotation
	local deltaRotation = lastCameraRotation:ToObjectSpace(cameraRotation)
	lastCameraRotation = cameraRotation

	local _, yaw, _ = deltaRotation:ToEulerAnglesYXZ()
	local swayTarget = CFrame.Angles(-yaw * vm.swayAmount, yaw * vm.swayAmount, 0)
	swayOffset = springToward(swayOffset, swayTarget, vm.springDamping, vm.swaySpeed, dt)

	local humanoid = getHumanoid()
	local speed = 0
	if humanoid then
		speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	end
	local bobTime = os.clock() * vm.bobSpeed
	local bobTarget = CFrame.new(0, math.sin(bobTime) * vm.bobAmount * (speed / 16), 0)
	bobOffset = springToward(bobOffset, bobTarget, vm.springDamping, vm.bobSpeed, dt)

	kickOffset = springToward(kickOffset, CFrame.identity, vm.springDamping, vm.fireKickRecovery, dt)

	local finalCFrame = cam.CFrame * vm.baseOffsetCFrame * swayOffset * bobOffset * kickOffset
	viewmodelRoot:PivotTo(finalCFrame)
end

function ViewmodelController.start(remoteTable: Remotes)
	remotes = remoteTable

	remoteTable.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?)
		if ok and weaponId then
			showViewmodel(weaponId)
		else
			destroyViewmodel()
		end
	end)

	remoteTable.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?, weaponId: string?)
		if kind == "Weapon" and weaponId then
			showViewmodel(weaponId)
		elseif kind == "None" then
			destroyViewmodel()
		end
	end)

	if Config.Input.forceFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end

	RunService:BindToRenderStep("ViewmodelControllerUpdate", Enum.RenderPriority.Camera.Value + 3, function(dt)
		updateViewmodel(dt)
	end)
end

return ViewmodelController
