--!strict
-- Module: ViewmodelController  (client-side)
-- First-person arms + gun cosmetic controller. Blueprint §11.4.
-- State machine: Empty ↔ Weapon.
--   EquipResult(true, weaponId) / HoldStateChanged("Weapon") → show arms+gun
--   HoldStateChanged("None")                                  → hide
--
-- Per-frame (RenderStepped):
--   base = camera.CFrame * Config.Viewmodel.baseOffset
--   + look-sway  (camera delta → spring-smoothed tilt)
--   + walk-bob   (sine × humanoid speed)
--
-- Ported and expanded from dbc1 ViewmodelController. Key change: sway is driven
-- by own mouse-delta tracking via UserInputService (not via DragController),
-- since sway should persist while firing, not only while dragging.
-- Exposes getMuzzlePosition() and playFireKick() for WeaponController.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local player = Players.LocalPlayer

-- -------------------------------------------------------------------------
-- Fallback viewmodel builder (used when no Studio asset is found)
-- -------------------------------------------------------------------------

local function buildFallbackViewmodel(weaponName: string): Model
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

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = body

	return model
end

local function ensurePrimaryPart(viewmodel: Model): BasePart
	if viewmodel.PrimaryPart then
		return viewmodel.PrimaryPart
	end
	local first = viewmodel:FindFirstChildWhichIsA("BasePart", true)
	if first then
		viewmodel.PrimaryPart = first
		return first
	end
	-- Create an invisible root if none exists.
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.35, 0.35, 0.35)
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.Parent = viewmodel
	viewmodel.PrimaryPart = root
	return root
end

-- -------------------------------------------------------------------------
-- ViewmodelController class
-- -------------------------------------------------------------------------

local ViewmodelController = {}
ViewmodelController.__index = ViewmodelController

function ViewmodelController.new()
	local self = setmetatable({}, ViewmodelController)
	self._currentWeaponId = nil :: string?
	self._viewmodel = nil :: Model?
	self._connections = {}
	self._renderConnection = nil

	-- Sway state.
	self._rawMouseDelta = Vector2.zero
	self._currentSway = CFrame.new()

	-- Bob state.
	self._bobTime = 0

	-- Fire-kick state: a small downward impulse applied on shot.
	self._kickOffset = Vector3.zero

	return self
end

-- -------------------------------------------------------------------------
-- Weapon show/hide
-- -------------------------------------------------------------------------

function ViewmodelController:_destroyViewmodel()
	if self._viewmodel then
		self._viewmodel:Destroy()
		self._viewmodel = nil
	end
	self._currentWeaponId = nil
end

function ViewmodelController:equip(weaponId: string)
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		warn("[ViewmodelController] Unknown weaponId:", weaponId)
		return
	end

	self:_destroyViewmodel()
	self._currentWeaponId = weaponId

	-- Try to find a Studio asset, fall back to procedural placeholder.
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vmFolder = assets and assets:FindFirstChild("Viewmodels")
	local template = vmFolder and vmFolder:FindFirstChild(def.viewmodelName)

	local vm: Model
	if template and template:IsA("Model") then
		vm = template:Clone()
	else
		vm = buildFallbackViewmodel(def.viewmodelName)
	end

	ensurePrimaryPart(vm)
	for _, desc in vm:GetDescendants() do
		if desc:IsA("BasePart") then
			(desc :: BasePart).Anchored = true
			(desc :: BasePart).CanCollide = false
			(desc :: BasePart).CanQuery = false
			(desc :: BasePart).CanTouch = false
		end
	end

	local cam = Workspace.CurrentCamera
	if cam then vm.Parent = cam end
	self._viewmodel = vm
end

function ViewmodelController:unequip()
	self:_destroyViewmodel()
	self._currentSway = CFrame.new()
	self._kickOffset = Vector3.zero
end

-- -------------------------------------------------------------------------
-- Visual effects exposed to WeaponController
-- -------------------------------------------------------------------------

-- Returns the world-space muzzle position (for tracer/shell origin).
function ViewmodelController:getMuzzlePosition(): Vector3?
	local vm = self._viewmodel
	if not vm or not vm.PrimaryPart then return nil end
	local def = self._currentWeaponId and ItemRegistry.getWeaponDef(self._currentWeaponId)
	if not def then return nil end
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	return cam.CFrame:PointToWorldSpace(def.muzzleOffset.Position)
end

-- Applies a visible downward kick to the viewmodel on fire.
function ViewmodelController:playFireKick()
	self._kickOffset = Vector3.new(0, -0.06, 0.04)
end

-- -------------------------------------------------------------------------
-- Render loop
-- -------------------------------------------------------------------------

function ViewmodelController:start()
	-- Track mouse delta independently for sway (works while firing, inspecting, etc.).
	table.insert(self._connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				self._rawMouseDelta = Vector2.new(input.Delta.X, input.Delta.Y)
			end
		end)
	)

	-- Camera replacement guard.
	table.insert(self._connections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			local vm = self._viewmodel
			if vm then
				vm.Parent = Workspace.CurrentCamera
			end
		end)
	)

	-- Force first-person lock.
	player.CameraMode = Enum.CameraMode.LockFirstPerson

	self._renderConnection = RunService.RenderStepped:Connect(function(dt: number)
		local vm = self._viewmodel
		local cam = Workspace.CurrentCamera
		if not vm or not cam then
			-- Keep mouse delta decaying even when no viewmodel.
			self._rawMouseDelta = Vector2.zero
			return
		end

		-- Reparent if camera was replaced.
		if vm.Parent ~= cam then
			vm.Parent = cam
		end

		local cfg = Config.Viewmodel

		-- Sway: camera look delta → CFrame tilt.
		local delta = self._rawMouseDelta
		self._rawMouseDelta = Vector2.zero

		delta = Vector2.new(
			math.clamp(delta.X, -cfg.dragClamp.X, cfg.dragClamp.X),
			math.clamp(delta.Y, -cfg.dragClamp.Y, cfg.dragClamp.Y)
		)

		local swayTarget = CFrame.Angles(
			-delta.Y * cfg.mouseSwayScale,
			-delta.X * cfg.mouseSwayScale,
			0
		)
		self._currentSway = self._currentSway:Lerp(
			swayTarget,
			math.clamp(dt * cfg.mouseSwayLerpSpeed, 0, 1)
		)

		-- Walk bob: sine wave scaled by horizontal speed.
		local char = player.Character
		local rootPart = char and char:FindFirstChild("HumanoidRootPart")
		local speed = 0
		if rootPart and rootPart:IsA("BasePart") then
			local vel = (rootPart :: BasePart).AssemblyLinearVelocity
			speed = Vector2.new(vel.X, vel.Z).Magnitude
		end
		self._bobTime += dt * cfg.bobSpeed * math.clamp(speed / 16, 0, 1)
		local bobY = math.sin(self._bobTime) * cfg.bobAmount * math.clamp(speed / 16, 0, 1)

		-- Kick decay.
		self._kickOffset = self._kickOffset:Lerp(Vector3.zero, math.clamp(dt * 20, 0, 1))

		local baseCF = cam.CFrame * cfg.baseOffset
		local finalCF = baseCF * CFrame.new(self._kickOffset + Vector3.new(0, bobY, 0)) * self._currentSway
		vm:PivotTo(finalCF)
	end)
end

function ViewmodelController:destroy()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
	for _, c in self._connections do c:Disconnect() end
	self._connections = {}
	self:_destroyViewmodel()
end

return ViewmodelController
