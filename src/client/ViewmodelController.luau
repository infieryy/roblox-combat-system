--!strict
-- Module: First-person cosmetic arms/viewmodel renderer.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))
type RemotesClientModule = typeof(require(script.Parent.RemotesClient))
type ClientRemotes = RemotesClientModule.ClientRemotes

local ViewmodelController = {}

local localPlayer = Players.LocalPlayer
local started = false
local remotes: ClientRemotes? = nil

local activeModel: Model? = nil
local activeWeaponId: string? = nil
local holdKind: "Weapon" | "Prop" | "None" = "None"
local lastCameraCF: CFrame? = nil
local bobTime = 0
local kickOffset = 0

local function clearViewmodel()
	if activeModel then
		activeModel:Destroy()
		activeModel = nil
	end
	activeWeaponId = nil
end

local function makeProceduralViewmodel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local arms = Instance.new("Part")
	arms.Name = "Arms"
	arms.Size = Vector3.new(0.8, 1.1, 1.1)
	arms.Transparency = 0.2
	arms.Color = Color3.fromRGB(220, 210, 190)
	arms.CanCollide = false
	arms.CanQuery = false
	arms.Anchored = true
	arms.Parent = model

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.25, 0.25, 1.5)
	barrel.Color = Color3.fromRGB(35, 35, 35)
	barrel.CanCollide = false
	barrel.CanQuery = false
	barrel.Anchored = true
	barrel.Parent = model

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -0.75)
	muzzle.Parent = barrel

	model.PrimaryPart = arms
	return model
end

local function loadViewmodelForWeapon(weaponId: string)
	clearViewmodel()

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end

	local folder = ReplicatedStorage:FindFirstChild("Viewmodels")
	local sourceModel = if folder then folder:FindFirstChild(def.viewmodelName) else nil
	local model: Model
	if sourceModel and sourceModel:IsA("Model") then
		model = sourceModel:Clone()
	else
		model = makeProceduralViewmodel(def.viewmodelName)
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.Massless = true
			descendant.Anchored = true
			descendant.CastShadow = false
		end
	end

	if not model.PrimaryPart then
		local firstPart = model:FindFirstChildWhichIsA("BasePart")
		if firstPart then
			model.PrimaryPart = firstPart
		end
	end

	model.Parent = workspace.CurrentCamera
	activeModel = model
	activeWeaponId = weaponId
end

local function updateViewmodel(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	lastCameraCF = lastCameraCF or camera.CFrame

	if holdKind ~= "Weapon" then
		if activeModel then
			clearViewmodel()
		end
		lastCameraCF = camera.CFrame
		return
	end

	if not activeModel and activeWeaponId then
		loadViewmodelForWeapon(activeWeaponId)
	end
	if not activeModel or not activeModel.PrimaryPart then
		lastCameraCF = camera.CFrame
		return
	end

	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local moveSpeed = if humanoid then humanoid.MoveDirection.Magnitude else 0
	bobTime += dt * Config.Viewmodel.bobSpeed * math.max(moveSpeed, 0.25)
	local bobY = math.sin(bobTime) * Config.Viewmodel.bobAmount * moveSpeed

	local delta = lastCameraCF:ToObjectSpace(camera.CFrame)
	local _, yaw, _ = delta:ToEulerAnglesYXZ()
	local pitch = math.asin(math.clamp(delta.LookVector.Y, -1, 1))
	local sway = CFrame.Angles(-pitch * Config.Viewmodel.swayAmount, -yaw * Config.Viewmodel.swayAmount, 0)

	kickOffset = math.max(0, kickOffset - dt * Config.Viewmodel.kickReturnSpeed)
	local kick = CFrame.new(0, 0, kickOffset)

	local target = camera.CFrame * Config.Viewmodel.baseOffsetCFrame * sway * CFrame.new(0, bobY, 0) * kick
	activeModel:PivotTo(target)
	lastCameraCF = camera.CFrame
end

function ViewmodelController.start(remoteBundle: ClientRemotes)
	if started then
		return
	end
	started = true
	remotes = remoteBundle

	localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?)
		if ok and weaponId then
			activeWeaponId = weaponId
			holdKind = "Weapon"
			loadViewmodelForWeapon(weaponId)
		end
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind == "Weapon" then
			holdKind = "Weapon"
		elseif kind == "Prop" or kind == "None" then
			holdKind = kind
			if kind ~= "Weapon" then
				clearViewmodel()
			end
		end
	end)

	RunService:BindToRenderStep("ItemSystemViewmodel", Enum.RenderPriority.Camera.Value + 3, updateViewmodel)
end

function ViewmodelController.getMuzzlePosition(): Vector3?
	if not activeModel then
		return nil
	end
	local muzzle = activeModel:FindFirstChild("Muzzle", true)
	if muzzle and muzzle:IsA("Attachment") then
		return muzzle.WorldPosition
	end
	if activeModel.PrimaryPart then
		return activeModel.PrimaryPart.Position
	end
	return nil
end

function ViewmodelController.playFireKick()
	kickOffset = math.max(kickOffset, Config.Viewmodel.kickDistance)
end

return ViewmodelController
