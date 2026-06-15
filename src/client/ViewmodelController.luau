--!strict
-- Module: client/ViewmodelController
-- New. Owns the first-person camera lock and renders a camera-attached,
-- local-only arms+gun viewmodel with look-sway, walk-bob and a fire recoil
-- kick. Cosmetic only — never authoritative for aim. The model is built
-- procedurally (zero external assets) and keyed off the weapon def's
-- viewmodelName, so it works out of the box.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

type Viewmodel = {
	model: Model,
	root: BasePart,
	muzzle: Attachment,
}

local VmCfg = Config.Viewmodel

local ViewmodelController = {}

local ctx: Context = nil :: any
local player = Players.LocalPlayer

local current: Viewmodel? = nil
local currentWeaponId: string? = nil

-- Smoothing state.
local swayPos = Vector3.zero
local swayRot = Vector2.zero
local bobTime = 0
local recoilOffset = CFrame.identity

----------------------------------------------------------------------
-- Procedural viewmodel construction.
----------------------------------------------------------------------

local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Builds the viewmodel in local space around the origin (root at identity). The
-- shape is tuned per weapon family but always returns a root + muzzle.
local function buildViewmodel(viewmodelName: string): Viewmodel
	local model = Instance.new("Model")
	model.Name = "Viewmodel_" .. viewmodelName

	-- Dimensions per family.
	local bodyLength = 1.6
	local barrelLength = 1.4
	if viewmodelName == "Rifle" then
		bodyLength = 2.0
		barrelLength = 2.2
	elseif viewmodelName == "Shotgun" then
		bodyLength = 1.8
		barrelLength = 1.9
	end

	local gunColor = Color3.fromRGB(40, 42, 48)
	local metalColor = Color3.fromRGB(70, 72, 78)
	local skinColor = Color3.fromRGB(225, 190, 160)

	-- Root = gun body. Built at the origin; everything else is offset from it.
	local root = makePart("Body", Vector3.new(0.28, 0.34, bodyLength), gunColor, Enum.Material.Metal)
	root.CFrame = CFrame.identity
	root.Parent = model
	model.PrimaryPart = root

	local barrel = makePart("Barrel", Vector3.new(0.16, 0.16, barrelLength), metalColor, Enum.Material.Metal)
	barrel.CFrame = root.CFrame * CFrame.new(0, 0.06, -(bodyLength / 2 + barrelLength / 2))
	barrel.Parent = model

	local grip = makePart("Grip", Vector3.new(0.22, 0.5, 0.26), gunColor, Enum.Material.SmoothPlastic)
	grip.CFrame = root.CFrame * CFrame.new(0, -0.36, bodyLength / 2 - 0.3) * CFrame.Angles(math.rad(-12), 0, 0)
	grip.Parent = model

	local sight = makePart("Sight", Vector3.new(0.06, 0.12, 0.18), metalColor, Enum.Material.Metal)
	sight.CFrame = root.CFrame * CFrame.new(0, 0.26, -0.1)
	sight.Parent = model

	-- Right forearm + hand (toward the grip).
	local rightArm = makePart("RightArm", Vector3.new(0.26, 0.26, 1.1), skinColor, Enum.Material.SmoothPlastic)
	rightArm.CFrame = root.CFrame * CFrame.new(0.18, -0.62, bodyLength / 2 + 0.2) * CFrame.Angles(math.rad(-55), 0, 0)
	rightArm.Parent = model

	-- Left forearm + hand (supporting the barrel).
	local leftArm = makePart("LeftArm", Vector3.new(0.26, 0.26, 1.1), skinColor, Enum.Material.SmoothPlastic)
	leftArm.CFrame = root.CFrame
		* CFrame.new(-0.28, -0.5, -(bodyLength / 2))
		* CFrame.Angles(math.rad(-45), math.rad(18), 0)
	leftArm.Parent = model

	-- Muzzle marker at the barrel tip.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Parent = barrel
	muzzle.Position = Vector3.new(0, 0, -barrelLength / 2)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 0
		end
	end

	return { model = model, root = root, muzzle = muzzle }
end

----------------------------------------------------------------------
-- Show / hide.
----------------------------------------------------------------------

local function hide()
	if current then
		current.model:Destroy()
		current = nil
	end
	currentWeaponId = nil
	recoilOffset = CFrame.identity
end

local function show(weaponId: string)
	if currentWeaponId == weaponId and current then
		return
	end
	hide()
	local def = ItemRegistry.getWeaponDef(weaponId)
	local viewmodelName = def and def.viewmodelName or "Pistol"
	local vm = buildViewmodel(viewmodelName)
	local cam = Workspace.CurrentCamera
	vm.model.Parent = cam or Workspace
	current = vm
	currentWeaponId = weaponId
end

----------------------------------------------------------------------
-- Public (used by WeaponController).
----------------------------------------------------------------------

function ViewmodelController.getMuzzlePosition(): Vector3?
	if current then
		return current.muzzle.WorldPosition
	end
	return nil
end

function ViewmodelController.isVisible(): boolean
	return current ~= nil
end

function ViewmodelController.playFireKick()
	if not current then
		return
	end
	recoilOffset = recoilOffset * VmCfg.recoilKick
end

----------------------------------------------------------------------
-- Per-frame render.
----------------------------------------------------------------------

local function getMoveSpeed(): number
	local char = player.Character
	if not char then
		return 0
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local v = root.AssemblyLinearVelocity
		return Vector3.new(v.X, 0, v.Z).Magnitude
	end
	return 0
end

local function render(dt: number)
	local vm = current
	if not vm then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	-- Keep the model parented to the live camera.
	if vm.model.Parent ~= cam then
		vm.model.Parent = cam
	end

	-- Look-sway from mouse delta (mouse is locked in first person).
	local md = UserInputService:GetMouseDelta()
	local targetSwayPos = Vector3.new(
		math.clamp(-md.X * 0.0006 * VmCfg.swayAmount * 100, -VmCfg.swayMaxOffset, VmCfg.swayMaxOffset),
		math.clamp(md.Y * 0.0006 * VmCfg.swayAmount * 100, -VmCfg.swayMaxOffset, VmCfg.swayMaxOffset),
		0
	)
	local targetSwayRot = Vector2.new(
		math.clamp(md.Y * 0.0006 * VmCfg.swayRotationAmount * 100, -0.2, 0.2),
		math.clamp(-md.X * 0.0006 * VmCfg.swayRotationAmount * 100, -0.2, 0.2)
	)
	local alpha = math.clamp(dt * 10, 0, 1)
	swayPos = swayPos:Lerp(targetSwayPos, alpha)
	swayRot = swayRot:Lerp(targetSwayRot, alpha)

	-- Walk-bob.
	local speed = getMoveSpeed()
	local moveFactor = math.clamp(speed / 16, 0, 1)
	bobTime += dt * VmCfg.bobSpeed * (speed > 0.5 and 1 or 0)
	local bob = Vector3.new(
		math.cos(bobTime) * VmCfg.bobAmount * moveFactor,
		math.abs(math.sin(bobTime)) * VmCfg.bobAmount * moveFactor,
		0
	)

	-- Recoil springs back toward identity.
	recoilOffset = recoilOffset:Lerp(CFrame.identity, math.clamp(dt * VmCfg.springDamping, 0, 1))

	local base = cam.CFrame * VmCfg.baseOffsetCFrame
	local swayCFrame = CFrame.new(swayPos + bob) * CFrame.Angles(swayRot.X, swayRot.Y, 0)
	local finalCFrame = base * swayCFrame * recoilOffset
	vm.model:PivotTo(finalCFrame)
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function lockFirstPerson()
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

function ViewmodelController.start(context: Context)
	ctx = context

	lockFirstPerson()

	ctx.remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?)
		if kind == "Weapon" and instance then
			local weaponId = ItemRegistry.getWeaponId(instance)
			if weaponId then
				show(weaponId)
			end
		else
			hide()
		end
	end)

	ctx.remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?)
		if ok and weaponId then
			show(weaponId)
		end
	end)

	player.CharacterAdded:Connect(function()
		lockFirstPerson()
		hide()
	end)

	-- Render just after the camera so we read the freshest CFrame.
	RunService:BindToRenderStep("ViewmodelRender", Enum.RenderPriority.Camera.Value + 1, render)
end

return ViewmodelController
