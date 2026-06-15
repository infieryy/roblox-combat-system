--!strict
--[[
	ViewmodelController  (client/ViewmodelController.luau → StarterPlayerScripts.Client.ViewmodelController)
	-----------------------------------------------------------------------------------------------------------
	Owns the first-person viewmodel: camera-attached arms + gun that only the
	local player sees. Completely cosmetic — never authoritative for hit detection.

	State machine:  Empty ←→ Weapon
	  • On EquipResult(true, weaponId) / HoldStateChanged("Weapon"):
	      Looks for a Model named def.viewmodelName in ReplicatedStorage.
	      Clones it and parents to workspace.CurrentCamera (renders only locally).
	  • On HoldStateChanged("None") / EquipResult(false): destroys the model.

	RenderStepped:
	  base   = camera.CFrame * Config.Viewmodel.baseOffsetCFrame
	  sway   = spring on camera rotation delta (lags behind head movement)
	  bob    = sine wave driven by humanoid WalkSpeed × time
	  kick   = recoil spring pulse applied by WeaponController on fire

	Exposed:
	  getMuzzlePosition() → Vector3   (for tracer origin)
	  playFireKick()                  (impulse into recoil spring)
	  start()                         (called from init.client)
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Config        = require(Shared:WaitForChild("Config"))
local ItemRegistry  = require(Shared:WaitForChild("ItemRegistry"))
local RemotesClient = require(script.Parent:WaitForChild("RemotesClient"))

local LocalPlayer = Players.LocalPlayer

-- ─────────────────────────────────────────────────────────────────────────────
-- Spring helpers
-- ─────────────────────────────────────────────────────────────────────────────

type Spring = { position: number, velocity: number }

local function makeSpring(): Spring
	return { position = 0, velocity = 0 }
end

-- Critical-damped spring: natural frequency `freq` (rad/s), damping ratio `damp`.
local function tickSpring(spring: Spring, target: number, dt: number, freq: number, damp: number): number
	local displacement = spring.position - target
	local force = -freq * freq * displacement - 2 * damp * freq * spring.velocity
	spring.velocity += force * dt
	spring.position += spring.velocity * dt
	return spring.position
end

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

local ViewmodelController = {}

-- Currently active viewmodel clone, if any.
local viewmodelModel: Model? = nil

-- Springs for look-sway.
local swaySpringX = makeSpring()
local swaySpringY = makeSpring()

-- Spring for recoil kick (applied as pitch offset).
local kickSpring  = makeSpring()

-- Walk-bob accumulator.
local bobTime = 0

-- Previous camera rotation (for delta calculation).
local prevCamCF: CFrame? = nil

-- Current equipped weaponId (for external queries).
local equippedWeaponId: string? = nil

-- ─────────────────────────────────────────────────────────────────────────────
-- Model management
-- ─────────────────────────────────────────────────────────────────────────────

local function hideWorldSpaceWeapon(weaponInstance: Instance?)
	-- Make the server-attached weapon invisible to the local player so they
	-- don't see a floating third-person gun on their own screen.
	if not weaponInstance then return end
	for _, part in weaponInstance:GetDescendants() do
		if part:IsA("BasePart") then
			(part :: BasePart).LocalTransparencyModifier = 1
		end
	end
end

local function showWorldSpaceWeapon(weaponInstance: Instance?)
	if not weaponInstance then return end
	for _, part in weaponInstance:GetDescendants() do
		if part:IsA("BasePart") then
			(part :: BasePart).LocalTransparencyModifier = 0
		end
	end
end

local function destroyViewmodel()
	if viewmodelModel then
		viewmodelModel:Destroy()
		viewmodelModel = nil
	end
	-- Reset springs on hide.
	swaySpringX = makeSpring()
	swaySpringY = makeSpring()
	kickSpring  = makeSpring()
	bobTime     = 0
	equippedWeaponId = nil
end

local function buildViewmodel(weaponId: string, worldWeapon: Instance?)
	destroyViewmodel()

	equippedWeaponId = weaponId

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end

	-- Look for the template in ReplicatedStorage.
	local template = ReplicatedStorage:FindFirstChild(def.viewmodelName)
	if not template or not template:IsA("Model") then
		-- No viewmodel asset provided — arms simply won't appear.
		-- This is not a fatal error; everything else (ammo HUD, shooting) still works.
		warn(string.format("[ViewmodelController] Viewmodel template '%s' not found in ReplicatedStorage.", def.viewmodelName))
		return
	end

	local clone = (template :: Model):Clone()
	clone.Name = "ActiveViewmodel"
	clone.Parent = workspace.CurrentCamera

	viewmodelModel = clone

	-- Hide the world-space weapon that the server attached to the character so
	-- the local player doesn't see a duplicate floating model.
	hideWorldSpaceWeapon(worldWeapon)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the world position of the muzzle for tracer/smoke effects.
function ViewmodelController.getMuzzlePosition(): Vector3
	local vm = viewmodelModel
	if vm then
		local muzzle = vm:FindFirstChild("Muzzle", true)
		if muzzle and muzzle:IsA("Attachment") then
			return (muzzle :: Attachment).WorldPosition
		end
		local muzzlePart = vm:FindFirstChild("MuzzlePart", true)
		if muzzlePart and muzzlePart:IsA("BasePart") then
			return (muzzlePart :: BasePart).Position
		end
		-- Fallback: rough camera forward point.
		local camera = workspace.CurrentCamera
		return camera.CFrame.Position + camera.CFrame.LookVector * 2
	end
	local camera = workspace.CurrentCamera
	return camera.CFrame.Position + camera.CFrame.LookVector * 2
end

-- Apply a recoil kick impulse (called by WeaponController on fire).
function ViewmodelController.playFireKick()
	kickSpring.velocity -= Config.Viewmodel.kickVelocity
end

function ViewmodelController.getEquippedWeaponId(): string?
	return equippedWeaponId
end

function ViewmodelController.hasViewmodel(): boolean
	return viewmodelModel ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-frame update
-- ─────────────────────────────────────────────────────────────────────────────

local function onRenderStep(dt: number)
	local vm = viewmodelModel
	if not vm then
		prevCamCF = nil
		return
	end

	local camera = workspace.CurrentCamera
	local camCF  = camera.CFrame

	-- ── Look-sway ────────────────────────────────────────────────────────
	-- Mouse delta is more reliable than decomposing the camera CFrame delta
	-- because it accumulates sub-pixel movement that CFrame rounding drops.
	local deltaX, deltaY = 0, 0
	if prevCamCF then
		local mouseDelta = UserInputService:GetMouseDelta()
		deltaX = mouseDelta.X
		deltaY = mouseDelta.Y
	end
	prevCamCF = camCF

	local freq = Config.Viewmodel.springFrequency
	local damp = Config.Viewmodel.springDamping

	local swayX = tickSpring(swaySpringX, -deltaX * Config.Viewmodel.swayAmount, dt, freq, damp)
	local swayY = tickSpring(swaySpringY, -deltaY * Config.Viewmodel.swayAmount, dt, freq, damp)

	-- ── Recoil kick ───────────────────────────────────────────────────────
	local kickVal = tickSpring(kickSpring, 0, dt, freq * 1.5, damp * 0.8)

	-- ── Walk-bob ─────────────────────────────────────────────────────────
	local character = LocalPlayer.Character
	local humanoid  = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local speed = 0
	if humanoid then
		speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	end

	if speed > 0.5 then
		bobTime += dt * Config.Viewmodel.bobSpeed
	else
		-- Smoothly decay bob time toward zero.
		bobTime *= (1 - dt * 8)
	end

	local bobY = math.abs(math.sin(bobTime)) * Config.Viewmodel.bobAmount
	local bobX = math.sin(bobTime * 0.5)    * Config.Viewmodel.bobAmount * 0.5
	local bobOffset = Vector3.new(bobX, bobY, 0)

	-- ── Compose final CFrame ─────────────────────────────────────────────
	local swayCF = CFrame.Angles(
		math.rad(swayY + kickVal),
		math.rad(swayX),
		0
	)
	local baseCF = camCF * Config.Viewmodel.baseOffsetCFrame
	local finalCF = baseCF * swayCF + bobOffset

	-- Apply to viewmodel.
	if vm.PrimaryPart then
		vm:PivotTo(finalCF)
	else
		-- Fallback: move every part relative to finalCF.
		for _, part in vm:GetDescendants() do
			if part:IsA("BasePart") then
				(part :: BasePart).CFrame = finalCF
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Boot
-- ─────────────────────────────────────────────────────────────────────────────

function ViewmodelController.start()
	local remotes = RemotesClient.get()

	-- Lock first-person so the local arms and camera always align.
	LocalPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	remotes.EquipResult.OnClientEvent:Connect(function(
		ok: boolean,
		weaponId: string?,
		_ammo: number?
	)
		if ok and weaponId then
			-- Find the world-space weapon instance (parented to character by server).
			local character = LocalPlayer.Character
			local worldWeapon: Instance? = nil
			if character and weaponId then
				-- The server parents the weapon to the character; find it by attribute.
				for _, child in character:GetDescendants() do
					if child:IsA("Model") or child:IsA("BasePart") then
						if ItemRegistry.classify(child) == "Weapon"
							and child:GetAttribute("WeaponId") == weaponId
						then
							worldWeapon = child
							break
						end
					end
				end
			end
			buildViewmodel(weaponId, worldWeapon)
		else
			destroyViewmodel()
		end
	end)

	remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: Instance?, weaponId: string?)
		if kind == "None" then
			-- Restore world-space visibility if we had hidden it.
			if viewmodelModel then
				local character = LocalPlayer.Character
				if character then
					for _, child in character:GetDescendants() do
						if ItemRegistry.classify(child) == "Weapon" then
							showWorldSpaceWeapon(child)
						end
					end
				end
			end
			destroyViewmodel()
		elseif kind == "Weapon" and weaponId then
			buildViewmodel(weaponId, instance)
		end
	end)

	-- Re-attach viewmodel parent when camera changes.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if viewmodelModel and workspace.CurrentCamera then
			viewmodelModel.Parent = workspace.CurrentCamera
		end
	end)

	RunService:BindToRenderStep(
		"ViewmodelControllerUpdate",
		Enum.RenderPriority.Camera.Value + 3,
		onRenderStep
	)
end

return ViewmodelController
