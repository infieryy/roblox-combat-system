local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ViewmodelConfig = require(Shared:WaitForChild("Viewmodel"):WaitForChild("ViewmodelConfig"))
local WeaponDefinitions = require(Shared:WaitForChild("Weapons"):WaitForChild("WeaponDefinitions"))

local ViewmodelController = {}
ViewmodelController.__index = ViewmodelController

local function getOrCreatePrimaryPart(viewmodel)
	if viewmodel.PrimaryPart then
		return viewmodel.PrimaryPart
	end

	local firstBasePart = viewmodel:FindFirstChildWhichIsA("BasePart", true)
	if firstBasePart then
		viewmodel.PrimaryPart = firstBasePart
		return firstBasePart
	end

	local fallbackRoot = Instance.new("Part")
	fallbackRoot.Name = "Root"
	fallbackRoot.Size = Vector3.new(1, 1, 1)
	fallbackRoot.Anchored = true
	fallbackRoot.CanCollide = false
	fallbackRoot.CanQuery = false
	fallbackRoot.CanTouch = false
	fallbackRoot.Transparency = 1
	fallbackRoot.Parent = viewmodel
	viewmodel.PrimaryPart = fallbackRoot
	return fallbackRoot
end

local function buildFallbackViewmodel(weaponName)
	local model = Instance.new("Model")
	model.Name = weaponName

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.35, 0.35, 0.35)
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.Parent = model
	model.PrimaryPart = root

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(0.2, 0.2, 1.2)
	body.Color = Color3.fromRGB(30, 30, 30)
	body.Material = Enum.Material.Metal
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.CFrame = root.CFrame * CFrame.new(0, 0, -0.6)
	body.Parent = model

	local weldConstraint = Instance.new("WeldConstraint")
	weldConstraint.Part0 = root
	weldConstraint.Part1 = body
	weldConstraint.Parent = body

	return model
end

function ViewmodelController.new(dragController)
	local self = setmetatable({}, ViewmodelController)
	self.dragController = dragController
	self.currentWeaponId = nil
	self.viewmodel = nil
	self.currentSway = CFrame.new()
	self.currentDragOffset = Vector3.zero
	self.renderConnection = nil
	return self
end

function ViewmodelController:_destroyCurrentViewmodel()
	if self.viewmodel then
		self.viewmodel:Destroy()
		self.viewmodel = nil
	end
end

function ViewmodelController:EquipWeapon(weaponId)
	local weaponData = WeaponDefinitions.getWeapon(weaponId)
	if not weaponData then
		return
	end

	self.currentWeaponId = weaponId
	self:_destroyCurrentViewmodel()

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local viewmodelsFolder = assets and assets:FindFirstChild("Viewmodels")
	local template = viewmodelsFolder and viewmodelsFolder:FindFirstChild(weaponData.viewmodelName)

	if template and template:IsA("Model") then
		self.viewmodel = template:Clone()
	else
		self.viewmodel = buildFallbackViewmodel(weaponData.viewmodelName)
	end

	getOrCreatePrimaryPart(self.viewmodel)
	for _, descendant in ipairs(self.viewmodel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local camera = Workspace.CurrentCamera
	if camera then
		self.viewmodel.Parent = camera
	end
end

function ViewmodelController:Start()
	if self.renderConnection then
		return
	end

	self.renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if not self.viewmodel then
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		if self.viewmodel.Parent ~= camera then
			self.viewmodel.Parent = camera
		end

		local weaponData = self.currentWeaponId and WeaponDefinitions.getWeapon(self.currentWeaponId)
		if not weaponData then
			return
		end

		local dragDelta = self.dragController and self.dragController:GetSmoothedDelta() or Vector2.zero
		dragDelta = Vector2.new(
			math.clamp(dragDelta.X, -ViewmodelConfig.dragClamp.X, ViewmodelConfig.dragClamp.X),
			math.clamp(dragDelta.Y, -ViewmodelConfig.dragClamp.Y, ViewmodelConfig.dragClamp.Y)
		)

		local swayTarget = CFrame.Angles(
			-dragDelta.Y * ViewmodelConfig.mouseSwayScale,
			-dragDelta.X * ViewmodelConfig.mouseSwayScale,
			0
		)
		self.currentSway = self.currentSway:Lerp(swayTarget, math.clamp(deltaTime * ViewmodelConfig.mouseSwayLerpSpeed, 0, 1))

		local dragInfluence = weaponData.dragInfluence
		local dragOffsetTarget = Vector3.new(
			-dragDelta.X * dragInfluence.X,
			dragDelta.Y * dragInfluence.Y,
			math.abs(dragDelta.X) * dragInfluence.Z
		)
		self.currentDragOffset = self.currentDragOffset:Lerp(
			dragOffsetTarget,
			math.clamp(deltaTime * ViewmodelConfig.dragLerpSpeed, 0, 1)
		)

		local targetCFrame = camera.CFrame * ViewmodelConfig.baseOffset * CFrame.new(self.currentDragOffset) * self.currentSway
		self.viewmodel:PivotTo(targetCFrame)
	end)
end

function ViewmodelController:Destroy()
	if self.renderConnection then
		self.renderConnection:Disconnect()
		self.renderConnection = nil
	end
	self:_destroyCurrentViewmodel()
end

return ViewmodelController
