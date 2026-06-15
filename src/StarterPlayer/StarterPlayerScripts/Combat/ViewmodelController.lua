local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ViewmodelController = {}
ViewmodelController.__index = ViewmodelController

local VIEWMODEL_ASSET_ROOT = "Assets"
local VIEWMODEL_ASSET_FOLDER = "Viewmodels"

local function getCamera(): Camera
	local camera = workspace.CurrentCamera
	if camera then
		return camera
	end
	return workspace:WaitForChild("Camera") :: Camera
end

local function ensurePrimaryPart(model: Model): BasePart
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local candidate = model:FindFirstChildWhichIsA("BasePart", true)
	if not candidate then
		error(("Viewmodel '%s' has no BasePart"):format(model.Name))
	end
	model.PrimaryPart = candidate
	return candidate
end

local function buildFallbackViewmodel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 2)
	root.Color = Color3.fromRGB(45, 45, 45)
	root.Material = Enum.Material.Metal
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Anchored = true
	root.Parent = model
	model.PrimaryPart = root

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Size = Vector3.new(0.2, 0.2, 1.5)
	barrel.Color = Color3.fromRGB(20, 20, 20)
	barrel.Material = Enum.Material.Metal
	barrel.CanCollide = false
	barrel.CanQuery = false
	barrel.CanTouch = false
	barrel.Anchored = true
	barrel.CFrame = root.CFrame * CFrame.new(0, 0, -1.5)
	barrel.Parent = model

	return model
end

function ViewmodelController.new()
	local self = setmetatable({}, ViewmodelController)
	self.currentWeaponId = nil
	self.currentWeaponDefinition = nil
	self.currentModel = nil
	self.dragInfluence = 0
	self.sway = Vector2.zero
	self.swayVelocity = Vector2.zero
	self.timeAccumulator = 0
	return self
end

function ViewmodelController:resolveViewmodelAsset(viewmodelName: string): Model
	local assetsFolder = ReplicatedStorage:FindFirstChild(VIEWMODEL_ASSET_ROOT)
	if not assetsFolder then
		return buildFallbackViewmodel(viewmodelName)
	end

	local viewmodelFolder = assetsFolder:FindFirstChild(VIEWMODEL_ASSET_FOLDER)
	if not viewmodelFolder then
		return buildFallbackViewmodel(viewmodelName)
	end

	local source = viewmodelFolder:FindFirstChild(viewmodelName)
	if not source or not source:IsA("Model") then
		return buildFallbackViewmodel(viewmodelName)
	end

	return source:Clone()
end

function ViewmodelController:equip(weaponId: string, weaponDefinition)
	if self.currentWeaponId == weaponId then
		return
	end

	self:unequip()

	self.currentWeaponId = weaponId
	self.currentWeaponDefinition = weaponDefinition
	local viewmodel = self:resolveViewmodelAsset(weaponDefinition.viewmodelName)
	ensurePrimaryPart(viewmodel)

	for _, descendant in viewmodel:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.CastShadow = false
		end
	end

	viewmodel.Parent = getCamera()
	self.currentModel = viewmodel
	self.timeAccumulator = 0
	self.sway = Vector2.zero
	self.swayVelocity = Vector2.zero
end

function ViewmodelController:unequip()
	if self.currentModel then
		self.currentModel:Destroy()
		self.currentModel = nil
	end

	self.currentWeaponId = nil
	self.currentWeaponDefinition = nil
	self.dragInfluence = 0
	self.sway = Vector2.zero
	self.swayVelocity = Vector2.zero
end

function ViewmodelController:setDragInfluence(value: number)
	self.dragInfluence = math.clamp(value, 0, 1)
end

function ViewmodelController:update(dt: number, lookDelta: Vector2)
	if not self.currentModel or not self.currentWeaponDefinition then
		return
	end

	self.timeAccumulator += dt
	local camera = getCamera()

	local weaponDefinition = self.currentWeaponDefinition
	local bobX = math.sin(self.timeAccumulator * 8) * 0.02
	local bobY = math.cos(self.timeAccumulator * 12) * 0.02
	local swayTarget = Vector2.new(-lookDelta.X, -lookDelta.Y) * 0.003 * weaponDefinition.viewmodelSwayScale
	self.swayVelocity = self.swayVelocity:Lerp((swayTarget - self.sway) * 25, math.min(1, dt * 10))
	self.sway = self.sway + self.swayVelocity * dt

	local dragTiltX = -self.dragInfluence * 0.12
	local dragTiltY = self.dragInfluence * 0.06
	local baseOffset = weaponDefinition.viewmodelOffset
	local bobOffset = CFrame.new(bobX, bobY, 0)
	local swayOffset = CFrame.Angles(self.sway.Y + dragTiltX, self.sway.X + dragTiltY, 0)
	local finalCFrame = camera.CFrame * baseOffset * bobOffset * swayOffset

	self.currentModel:PivotTo(finalCFrame)
end

function ViewmodelController:destroy()
	self:unequip()
end

return ViewmodelController
