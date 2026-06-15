--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local ViewmodelController = {}

local currentWeaponId: string? = nil
local currentModel: Model? = nil
local swayOffset = Vector3.zero
local kickback = 0
local lastCameraCFrame: CFrame? = nil

local function destroyModel()
	if currentModel then
		currentModel:Destroy()
		currentModel = nil
	end
end

local function buildFallbackModel(weaponId: string): Model
	local model = Instance.new("Model")
	model.Name = "Viewmodel_" .. weaponId

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.6, 0.6, 1.4)
	root.Material = Enum.Material.SmoothPlastic
	root.Color = Color3.fromRGB(60, 60, 60)
	root.Anchored = true
	root.CanCollide = false
	root.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -0.8)
	muzzle.Parent = root

	model.PrimaryPart = root
	model.Parent = workspace.CurrentCamera
	return model
end

local function setWeapon(weaponId: string?)
	if currentWeaponId == weaponId then
		return
	end
	currentWeaponId = weaponId
	destroyModel()
	if not weaponId then
		return
	end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end

	local viewmodels = ReplicatedStorage:FindFirstChild("Viewmodels")
	if viewmodels and viewmodels:FindFirstChild(def.viewmodelName) then
		local template = viewmodels[def.viewmodelName]
		if template:IsA("Model") then
			currentModel = template:Clone()
			currentModel.Parent = workspace.CurrentCamera
			return
		end
	end

	currentModel = buildFallbackModel(weaponId)
end

local function getRootPart(): BasePart?
	if not currentModel then
		return nil
	end
	if currentModel.PrimaryPart then
		return currentModel.PrimaryPart
	end
	return currentModel:FindFirstChildWhichIsA("BasePart")
end

local function updateViewmodel(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local root = getRootPart()
	if not root then
		lastCameraCFrame = camera.CFrame
		return
	end

	local deltaCF = if lastCameraCFrame then lastCameraCFrame:ToObjectSpace(camera.CFrame) else CFrame.identity
	lastCameraCFrame = camera.CFrame

	local dx, dy, _ = deltaCF:ToEulerAnglesXYZ()
	local targetSway = Vector3.new(-dy, dx, 0) * Config.Viewmodel.swayAmount
	swayOffset = swayOffset:Lerp(targetSway, math.clamp(dt * Config.Viewmodel.swaySpeed, 0, 1))

	local humanoid = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	local speed = humanoid and humanoid.MoveDirection.Magnitude or 0
	local bob = math.sin(os.clock() * Config.Viewmodel.bobSpeed) * Config.Viewmodel.bobAmount * speed

	kickback = math.max(0, kickback - dt * 7)
	local kickOffset = CFrame.new(0, 0, -kickback)
	local swayCF = CFrame.Angles(swayOffset.Y, swayOffset.X, swayOffset.Z)
	local bobCF = CFrame.new(0, bob, 0)

	local final = camera.CFrame * Config.Viewmodel.baseOffset * bobCF * swayCF * kickOffset
	currentModel:PivotTo(final)
end

function ViewmodelController.onHoldStateChanged(state: any)
	if typeof(state) ~= "table" then
		return
	end
	if state.kind == "Weapon" and typeof(state.weaponId) == "string" then
		setWeapon(state.weaponId)
	else
		setWeapon(nil)
	end
end

function ViewmodelController.onEquipResult(success: boolean, weaponId: any)
	if success and typeof(weaponId) == "string" then
		setWeapon(weaponId)
	elseif not success then
		setWeapon(nil)
	end
end

function ViewmodelController.onFireKick()
	kickback = kickback + Config.Viewmodel.kickbackDistance
end

function ViewmodelController.getMuzzlePosition(): Vector3
	local root = getRootPart()
	if not root then
		local camera = workspace.CurrentCamera
		if not camera then
			return Vector3.zero
		end
		return camera.CFrame.Position + camera.CFrame.LookVector * 2
	end

	local muzzle = root:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	return root.Position + root.CFrame.LookVector * 1
end

function ViewmodelController.start()
	if Config.ForceFirstPerson then
		Players.LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
	end
	RunService.RenderStepped:Connect(updateViewmodel)
end

return ViewmodelController
