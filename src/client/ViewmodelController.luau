--!strict
-- Module: ViewmodelController
-- First-person cosmetic arms + gun viewmodel.
-- NEW — not present in the consensus build.
--
-- Responsibilities:
--   * Owns first-person camera lock (LockFirstPerson) for the whole client.
--   * State machine Empty ↔ Weapon:
--       EquipResult(true) / HoldStateChanged("Weapon") → show arms + gun model
--       HoldStateChanged("None") / EquipResult(false) → hide
--   * RenderStepped:
--       base position  = camera.CFrame * Config.Viewmodel.baseOffsetCFrame
--       look-sway      = camera-rotation delta, spring-smoothed, applied as rotation
--       walk-bob       = sine wave scaled by humanoid movement speed
--       fire-kick      = impulse applied by playFireKick(), spring-decays
--   * Cosmetic only — never authoritative for aim direction or damage.
--
-- Viewmodel models:
--   Place a Model named <def.viewmodelName> inside ReplicatedStorage.ViewmodelAssets.
--   If the model is absent the system works fine; arms simply won't appear.

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace        = game:GetService("Workspace")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Config  = require(Shared:WaitForChild("Config"))
local Types   = require(Shared:WaitForChild("Types"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))
local Remotes = require(script.Parent:WaitForChild("RemotesClient"))

local ViewmodelController = {}

local player   = Players.LocalPlayer
local camera   = Workspace.CurrentCamera

-- -------------------------------------------------------------------------
-- Spring system (used for sway and kick; a simple critically-damped spring)
-- -------------------------------------------------------------------------

type Spring = { position: number, velocity: number }

local function makeSpring(): Spring
	return { position = 0, velocity = 0 }
end

local function stepSpring(s: Spring, target: number, dt: number, frequency: number, damping: number): number
	local stiffness    = frequency * frequency
	local dampingCoeff = 2 * damping * frequency
	local accel        = stiffness * (target - s.position) - dampingCoeff * s.velocity
	s.velocity  += accel * dt
	s.position  += s.velocity * dt
	return s.position
end

-- 2D spring (horizontal + vertical sway)
type Spring2 = { x: Spring, y: Spring }

local function makeSpring2(): Spring2
	return { x = makeSpring(), y = makeSpring() }
end

local function stepSpring2(s: Spring2, tx: number, ty: number, dt: number, freq: number, damp: number): (number, number)
	return stepSpring(s.x, tx, dt, freq, damp), stepSpring(s.y, ty, dt, freq, damp)
end

-- -------------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------------

local viewmodelModel: Model? = nil          -- currently displayed model
local currentWeaponId: string? = nil

local swaySpring: Spring2  = makeSpring2()  -- look-lag sway
local kickSpring: Spring   = makeSpring()   -- fire kick (pitch)
local bobTime = 0

local lastCameraCFrame: CFrame = CFrame.identity
local isEquipped = false

-- -------------------------------------------------------------------------
-- Model management
-- -------------------------------------------------------------------------

local function findViewmodelAssets(): Folder?
	return ReplicatedStorage:FindFirstChild("ViewmodelAssets") :: Folder?
end

local function showViewModel(weaponId: string)
	-- Hide any previous model
	if viewmodelModel then
		viewmodelModel:Destroy()
		viewmodelModel = nil
	end

	currentWeaponId = weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		warn("[ViewmodelController] No weapon def for: " .. weaponId)
		return
	end

	local assets = findViewmodelAssets()
	if not assets then
		warn("[ViewmodelController] ReplicatedStorage.ViewmodelAssets folder not found.")
		warn("[ViewmodelController] Create it and place a Model named '" .. def.viewmodelName .. "' inside.")
		return
	end

	local template = assets:FindFirstChild(def.viewmodelName)
	if not template or not template:IsA("Model") then
		warn("[ViewmodelController] Viewmodel model '" .. def.viewmodelName .. "' not found in ViewmodelAssets.")
		return
	end

	local vm = (template :: Model):Clone()
	vm.Name   = "ActiveViewmodel"

	-- Hide all parts from third-person rendering (they should only appear to the local player).
	for _, part in vm:GetDescendants() do
		if part:IsA("BasePart") then
			part.CastShadow             = false
			part.LocalTransparencyModifier = 0
		end
	end

	vm.Parent    = camera
	viewmodelModel = vm
	isEquipped     = true

	-- Reset springs on equip so there's no initial snap.
	swaySpring = makeSpring2()
	kickSpring = makeSpring()
	bobTime    = 0
end

local function hideViewModel()
	if viewmodelModel then
		viewmodelModel:Destroy()
		viewmodelModel = nil
	end
	currentWeaponId = nil
	isEquipped      = false
end

-- -------------------------------------------------------------------------
-- RenderStep: position the viewmodel each frame
-- -------------------------------------------------------------------------

local function onRenderStep(dt: number)
	camera = Workspace.CurrentCamera
	if not camera then return end

	if not isEquipped or not viewmodelModel then
		lastCameraCFrame = camera.CFrame
		return
	end

	-- Camera rotation delta since last frame → drives the sway spring targets.
	-- We extract the euler Y (yaw) and X (pitch) delta.
	local camDelta    = lastCameraCFrame:ToObjectSpace(camera.CFrame)
	local rx, ry, _   = camDelta:ToEulerAnglesYXZ()
	lastCameraCFrame  = camera.CFrame

	local freq = Config.Viewmodel.springFrequency
	local damp = Config.Viewmodel.springDamping

	-- Sway: camera rotation delta pulls the viewmodel in the opposite direction.
	local swayAmount = Config.Viewmodel.swayAmount
	local swayTargX  = -ry * swayAmount   -- horizontal look delta → X sway
	local swayTargY  = -rx * swayAmount   -- vertical look delta   → Y sway
	local swayX, swayY = stepSpring2(swaySpring, swayTargX, swayTargY, dt, freq, damp)

	-- Kick: upward pitch impulse on fire, spring-decays to zero.
	local kickTarget = 0
	local kickVal    = stepSpring(kickSpring, kickTarget, dt, Config.Viewmodel.kickRecoverySpeed, damp)

	-- Walk bob: sine wave scaled by horizontal movement speed.
	local humanoidRootPart: BasePart? = nil
	if player.Character then
		humanoidRootPart = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	local movementSpeed = 0
	if humanoidRootPart then
		local vel = humanoidRootPart.AssemblyLinearVelocity
		movementSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	end

	bobTime += dt * Config.Viewmodel.bobSpeed * (movementSpeed / 16)
	local bobY  = math.abs(math.sin(bobTime)) * Config.Viewmodel.bobAmount * math.min(movementSpeed / 8, 1)
	local bobX  = math.sin(bobTime * 2)       * Config.Viewmodel.bobAmount * 0.4 * math.min(movementSpeed / 8, 1)

	-- Compose final CFrame.
	-- Base offset: position the viewmodel in front of, and slightly below, the camera.
	local baseOffset = Config.Viewmodel.baseOffsetCFrame

	-- Sway is applied as a rotation around the base offset origin.
	local swayRotation = CFrame.Angles(swayY + kickVal, swayX, 0)
	local bobOffset    = CFrame.new(bobX, -bobY, 0)

	local finalCF = camera.CFrame * baseOffset * bobOffset * swayRotation

	-- Position the PrimaryPart (or model pivot) at the computed CFrame.
	local primary = viewmodelModel.PrimaryPart
	if primary then
		viewmodelModel:SetPrimaryPartCFrame(finalCF)
	else
		viewmodelModel:PivotTo(finalCF)
	end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- Called from init.client.luau.
function ViewmodelController.start()
	-- Lock camera to first person (ported from consensus; viewmodel requires it).
	player.CameraMode = Enum.CameraMode.LockFirstPerson

	if player.Character then
		lastCameraCFrame = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or CFrame.identity
	end

	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = Workspace.CurrentCamera
		if camera then lastCameraCFrame = camera.CFrame end
	end)

	-- React to authoritative equip events.
	Remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: string?, _ammo: number?)
		if ok and weaponId then
			showViewModel(weaponId)
		else
			hideViewModel()
		end
	end)

	Remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, _instance: Instance?)
		if kind == "None" then
			hideViewModel()
		elseif kind == "Weapon" then
			-- weaponId comes from EquipResult; if we get HoldStateChanged("Weapon") without
			-- a prior EquipResult (e.g. reconnect), stay hidden until the next equip.
		end
	end)

	-- Character respawn: clear viewmodel.
	player.CharacterAdded:Connect(function()
		hideViewModel()
	end)

	RunService:BindToRenderStep(
		"ViewmodelControllerUpdate",
		Enum.RenderPriority.Camera.Value + 2,  -- after DragController
		onRenderStep
	)
end

-- Returns the world-space muzzle position for WeaponController to use as the fire origin.
-- Falls back to camera position + forward offset if no Muzzle part exists.
function ViewmodelController.getMuzzlePosition(): Vector3
	if viewmodelModel then
		local muzzle = viewmodelModel:FindFirstChild("Muzzle", true)
		if muzzle and muzzle:IsA("BasePart") then
			return muzzle.Position
		end
	end
	camera = Workspace.CurrentCamera
	if camera then
		return camera.CFrame.Position + camera.CFrame.LookVector * 2.5
	end
	return Vector3.zero
end

-- Apply a recoil kick impulse (called by WeaponController on confirmed/predicted fire).
function ViewmodelController.playFireKick()
	kickSpring.velocity -= Config.Viewmodel.kickPitch * 60  -- kick upward (negative pitch = up)
end

function ViewmodelController.isEquipped(): boolean
	return isEquipped
end

return ViewmodelController
