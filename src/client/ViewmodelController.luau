--!strict
-- Module: client/ViewmodelController
-- First-person arms + gun rendered only to the local player (BLUEPRINT.md §11.4,
-- NEW). Owns the first-person camera lock (ported LockFirstPerson). State machine
-- Empty <-> Weapon driven by EquipResult / HoldStateChanged. Layers look-sway and
-- walk-bob on top of a base offset, plus a recoil "fire kick". Purely cosmetic —
-- never authoritative for aim.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local VM = Config.Viewmodel

local ViewmodelController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local remotes: any = nil
local currentWeaponId: string? = nil
local model: Model? = nil
local muzzle: Attachment? = nil

-- Smoothed dynamic state.
local swayCFrame = CFrame.identity
local kickCFrame = CFrame.identity
local bobPhase = 0
local lastCamCFrame: CFrame? = nil

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

----------------------------------------------------------------------
-- Viewmodel construction. Prefers a designer asset at
-- ReplicatedStorage.Viewmodels[viewmodelName]; otherwise builds a procedural
-- arms+gun rig so the system is fully functional with no external assets.
----------------------------------------------------------------------

local function newPart(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	return part
end

local function weldTo(root: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = root.CFrame * offset
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = part
	weld.C0 = offset
	weld.Parent = root
end

local function buildProcedural(): (Model, Attachment)
	local rig = Instance.new("Model")
	rig.Name = "ProceduralViewmodel"

	local root = newPart("Root", Vector3.new(0.2, 0.2, 0.2), Color3.fromRGB(40, 40, 40))
	root.Transparency = 1
	rig.PrimaryPart = root
	root.Parent = rig

	local body = newPart("GunBody", Vector3.new(0.35, 0.55, 1.6), Color3.fromRGB(30, 30, 35))
	weldTo(root, body, CFrame.new(0, -0.1, -0.4))
	body.Parent = rig

	local barrel = newPart("Barrel", Vector3.new(0.18, 0.18, 1.2), Color3.fromRGB(20, 20, 22))
	weldTo(root, barrel, CFrame.new(0, 0.05, -1.1))
	barrel.Parent = rig

	local grip = newPart("Grip", Vector3.new(0.25, 0.6, 0.3), Color3.fromRGB(25, 25, 28))
	weldTo(root, grip, CFrame.new(0, -0.5, 0.1) * CFrame.Angles(math.rad(-15), 0, 0))
	grip.Parent = rig

	local rightArm = newPart("RightArm", Vector3.new(0.3, 0.3, 1.0), Color3.fromRGB(235, 200, 170))
	weldTo(root, rightArm, CFrame.new(0.25, -0.55, 0.6))
	rightArm.Parent = rig

	local leftArm = newPart("LeftArm", Vector3.new(0.3, 0.3, 0.9), Color3.fromRGB(235, 200, 170))
	weldTo(root, leftArm, CFrame.new(-0.3, -0.3, -0.5))
	leftArm.Parent = rig

	local muzzleAttachment = Instance.new("Attachment")
	muzzleAttachment.Name = "Muzzle"
	muzzleAttachment.CFrame = CFrame.new(0, 0.05, -1.7)
	muzzleAttachment.Parent = root

	return rig, muzzleAttachment
end

local function buildViewmodel(viewmodelName: string): (Model, Attachment)
	local container = ReplicatedStorage:FindFirstChild("Viewmodels")
	local template = container and container:FindFirstChild(viewmodelName)
	if template and template:IsA("Model") then
		local clone = template:Clone()
		local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
		if primary then
			clone.PrimaryPart = primary
			for _, part in clone:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = false
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = false
					part.Massless = true
				end
			end
			local muzzleAttachment = clone:FindFirstChild("Muzzle", true)
			if not (muzzleAttachment and muzzleAttachment:IsA("Attachment")) then
				local created = Instance.new("Attachment")
				created.Name = "Muzzle"
				created.CFrame = CFrame.new(0, 0, -primary.Size.Z)
				created.Parent = primary
				muzzleAttachment = created
			end
			return clone, muzzleAttachment :: Attachment
		end
		clone:Destroy()
	end
	return buildProcedural()
end

local function hideViewmodel()
	if model then
		model:Destroy()
		model = nil
	end
	muzzle = nil
	currentWeaponId = nil
	kickCFrame = CFrame.identity
	swayCFrame = CFrame.identity
end

local function showViewmodel(weaponId: string)
	if currentWeaponId == weaponId and model then
		return
	end
	hideViewmodel()
	local def = ItemRegistry.getWeaponDef(weaponId)
	local viewmodelName = def and def.viewmodelName or weaponId
	local rig, muzzleAttachment = buildViewmodel(viewmodelName)
	rig.Parent = getCamera() -- descendants of Camera render only to the local player
	model = rig
	muzzle = muzzleAttachment
	currentWeaponId = weaponId
end

----------------------------------------------------------------------
-- Public cosmetic hooks used by WeaponController.
----------------------------------------------------------------------

function ViewmodelController.getMuzzlePosition(): Vector3
	if muzzle then
		return muzzle.WorldPosition
	end
	local cam = getCamera()
	return cam and cam.CFrame.Position or Vector3.zero
end

function ViewmodelController.playFireKick()
	kickCFrame = VM.fireKick * kickCFrame
end

function ViewmodelController.isVisible(): boolean
	return model ~= nil
end

----------------------------------------------------------------------
-- Per-frame render.
----------------------------------------------------------------------

local function getHumanoidSpeed(): number
	local character = player.Character
	if not character then
		return 0
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	end
	return 0
end

local function onRender(dt: number)
	local cam = getCamera()
	if not cam or not model then
		lastCamCFrame = cam and cam.CFrame or nil
		return
	end

	local camCF = cam.CFrame

	-- Look-sway from the inter-frame camera rotation delta.
	local swayTarget = CFrame.identity
	if lastCamCFrame then
		local rel = lastCamCFrame.Rotation:Inverse() * camCF.Rotation
		local pitchDelta, yawDelta = rel:ToOrientation()
		local sx = math.clamp(-yawDelta * VM.swayAmount * 60, -VM.maxSwayOffset, VM.maxSwayOffset)
		local sy = math.clamp(pitchDelta * VM.swayAmount * 60, -VM.maxSwayOffset, VM.maxSwayOffset)
		swayTarget = CFrame.new(sx, sy, 0)
			* CFrame.Angles(pitchDelta * 1.5, yawDelta * 1.5, -yawDelta * 1.5)
	end
	local alpha = 1 - math.exp(-VM.swaySpeed * dt)
	swayCFrame = swayCFrame:Lerp(swayTarget, alpha)

	-- Walk-bob scaled by horizontal speed.
	local speed = getHumanoidSpeed()
	local speedRatio = math.clamp(speed / 16, 0, 1)
	bobPhase += dt * VM.bobSpeed * (0.3 + speedRatio)
	local bobX = math.cos(bobPhase) * VM.bobAmount * speedRatio
	local bobY = math.abs(math.sin(bobPhase)) * VM.bobAmount * speedRatio
	local bobCFrame = CFrame.new(bobX, bobY, 0)

	-- Recoil kick recovery toward identity.
	local kickAlpha = 1 - math.exp(-VM.fireKickRecover * dt)
	kickCFrame = kickCFrame:Lerp(CFrame.identity, kickAlpha)

	local finalCFrame = camCF * VM.baseOffsetCFrame * swayCFrame * bobCFrame * kickCFrame
	model:PivotTo(finalCFrame)

	lastCamCFrame = camCF
end

----------------------------------------------------------------------
-- Start.
----------------------------------------------------------------------

function ViewmodelController.start(remotesTable: any)
	remotes = remotesTable
	player.CameraMode = Enum.CameraMode.LockFirstPerson

	remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?)
		if ok and weaponId then
			showViewmodel(weaponId)
		end
	end)

	-- Authoritative hold state is the source of truth: show on Weapon, hide on
	-- anything else (Prop / None).
	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
		if kind ~= "Weapon" then
			hideViewmodel()
		end
	end)

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if Workspace.CurrentCamera then
			camera = Workspace.CurrentCamera
			if model then
				model.Parent = camera
			end
		end
	end)

	player.CharacterAdded:Connect(function()
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end)

	RunService:BindToRenderStep("ItemSystemViewmodel", Enum.RenderPriority.Camera.Value + 3, onRender)
end

return ViewmodelController
