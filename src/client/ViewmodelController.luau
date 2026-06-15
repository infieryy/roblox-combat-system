--!strict
--[[
	ViewmodelController (ModuleScript)
	----------------------------------
	Owns the first-person weapon model rendered in front of the player. It builds
	the viewmodel procedurally from a `WeaponConfig.WeaponDefinition` (no Studio
	assets required), then pins it to the SAME scriptable first-person camera that
	the pickup system already drives (`CameraController.getCFrame()`), so the two
	systems share one coherent first-person view.

	Per frame it applies:
	  * a smoothed "follow" so the gun lags the camera slightly (weighty feel),
	  * positional sway from how fast the camera is turning,
	  * idle/walk bob driven by the character's planar speed.

	It renders AFTER the camera and the pickup controller (RenderPriority
	Camera + 3) so it always reads a fresh camera CFrame, and it auto-hides while
	the player is carrying / inspecting a picked-up object (via HoldState), which
	is what keeps weapons and dragging from fighting over the screen.

	Viewmodel parts are CanCollide/CanQuery/CanTouch = false, so they never
	register in the weapon's own raycasts or shove the world.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))

local CameraController = require(script.Parent:WaitForChild("CameraController"))
local HoldState = require(script.Parent:WaitForChild("HoldState"))

local LocalPlayer = Players.LocalPlayer

local RENDER_NAME = "WeaponViewmodelUpdate"
-- After CameraController (Camera+1) and PickupController (Camera+2).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3

local ViewmodelController = {}

type PartEntry = {
	part: BasePart,
	localCFrame: CFrame,
	isMuzzle: boolean,
}

local started = false
local model: Model? = nil
local parts: { PartEntry } = {}
local muzzlePart: BasePart? = nil
local activeWeapon: WeaponConfig.WeaponDefinition? = nil

-- Smoothed transform the viewmodel is currently rendered at.
local smoothedCFrame = CFrame.identity
-- Bob phase accumulator and the previous camera look direction (for sway).
local bobPhase = 0
local lastLookVector = Vector3.zAxis
-- Recoil "kick" applied additively and decayed each frame.
local recoilOffset = Vector3.zero
local recoilRot = Vector3.zero

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

local function toVector3(v: WeaponConfig.Vector3Like): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

local function toColor(c: { r: number, g: number, b: number }): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local function localCFrameFor(p: WeaponConfig.ViewmodelPart): CFrame
	local offset = toVector3(p.Offset)
	local rot = toVector3(p.Rotation)
	return CFrame.new(offset)
		* CFrame.Angles(math.rad(rot.x), math.rad(rot.y), math.rad(rot.z))
end

local function getPlanarSpeed(): number
	local character = LocalPlayer.Character
	if not character then
		return 0
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return 0
	end
	local v = root.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

------------------------------------------------------------------
-- Build / destroy
------------------------------------------------------------------

local function destroyModel()
	if model then
		model:Destroy()
	end
	model = nil
	parts = {}
	muzzlePart = nil
	activeWeapon = nil
end

local function buildModel(weapon: WeaponConfig.WeaponDefinition)
	destroyModel()

	local container = Instance.new("Model")
	container.Name = "WeaponViewmodel"

	local newParts: { PartEntry } = {}
	local holdOffset = toVector3(weapon.HoldOffset)

	for _, partDef in weapon.Parts do
		local part = Instance.new("Part")
		part.Name = partDef.Name
		part.Size = toVector3(partDef.Size)
		part.Color = toColor(partDef.Color)
		part.Material = partDef.Material
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false
		part.Parent = container

		-- Local pose = hold offset (whole-gun placement) * the part's own pose.
		local localCFrame = CFrame.new(holdOffset) * localCFrameFor(partDef)
		local entry: PartEntry = {
			part = part,
			localCFrame = localCFrame,
			isMuzzle = partDef.IsMuzzle == true,
		}
		table.insert(newParts, entry)

		if entry.isMuzzle then
			muzzlePart = part
		end
	end

	container.Parent = workspace.CurrentCamera
	model = container
	parts = newParts
	activeWeapon = weapon
	-- Snap to the current camera so the gun doesn't "fly in" from the origin.
	smoothedCFrame = CameraController.getCFrame()
end

------------------------------------------------------------------
-- Per-frame render
------------------------------------------------------------------

local function setVisible(visible: boolean)
	for _, entry in parts do
		entry.part.LocalTransparencyModifier = visible and 0 or 1
	end
end

local function onRenderStep(dt: number)
	if not model or not activeWeapon then
		return
	end

	-- Holster instantly while dragging / inspecting an object.
	if HoldState.isHolding() then
		setVisible(false)
		return
	end
	setVisible(true)

	local weapon = activeWeapon
	local camCFrame = CameraController.getCFrame()

	-- Sway: react to how much the camera turned this frame.
	local look = camCFrame.LookVector
	local turn = look - lastLookVector
	lastLookVector = look
	local swayX = -turn:Dot(camCFrame.RightVector) * weapon.SwayAmount * 60
	local swayY = -turn:Dot(camCFrame.UpVector) * weapon.SwayAmount * 60

	-- Bob: advance phase by planar speed; amplitude scales with speed.
	local speed = getPlanarSpeed()
	bobPhase += dt * weapon.BobSpeed * (0.4 + math.clamp(speed / 16, 0, 1))
	local speedFactor = math.clamp(speed / 16, 0, 1)
	local bobX = math.cos(bobPhase) * weapon.BobAmplitude * speedFactor
	local bobY = math.abs(math.sin(bobPhase)) * weapon.BobAmplitude * speedFactor

	-- Decay recoil back to rest.
	local decay = math.clamp(dt * 10, 0, 1)
	recoilOffset = recoilOffset:Lerp(Vector3.zero, decay)
	recoilRot = recoilRot:Lerp(Vector3.zero, decay)

	-- Smoothly follow the camera (slight weighty lag).
	local alpha = 1 - math.exp(-weapon.FollowResponsiveness * dt)
	smoothedCFrame = smoothedCFrame:Lerp(camCFrame, alpha)

	local base = smoothedCFrame
		* CFrame.new(swayX + bobX + recoilOffset.X, swayY + bobY + recoilOffset.Y, recoilOffset.Z)
		* CFrame.Angles(recoilRot.X, recoilRot.Y, recoilRot.Z)

	for _, entry in parts do
		entry.part.CFrame = base * entry.localCFrame
	end
end

------------------------------------------------------------------
-- Public API
------------------------------------------------------------------

-- Build and show the viewmodel for a weapon definition.
function ViewmodelController.equip(weapon: WeaponConfig.WeaponDefinition)
	buildModel(weapon)
end

-- Tear down the current viewmodel.
function ViewmodelController.unequip()
	destroyModel()
end

function ViewmodelController.isEquipped(): boolean
	return model ~= nil
end

-- World-space muzzle position for spawning shot FX. Falls back to the camera
-- position if the weapon has no muzzle part.
function ViewmodelController.getMuzzlePosition(): Vector3
	if muzzlePart and muzzlePart.Parent then
		return muzzlePart.Position
	end
	return CameraController.getCFrame().Position
end

-- Apply a recoil kick (called by WeaponController on fire). `strength` scales
-- the backward/upward push and the muzzle climb.
function ViewmodelController.applyRecoil(strength: number)
	recoilOffset += Vector3.new(0, 0.02 * strength, 0.18 * strength)
	recoilRot += Vector3.new(math.rad(2.2 * strength), 0, 0)
end

function ViewmodelController.start()
	if started then
		return
	end
	started = true

	-- Rebuild under the new camera if Roblox swaps CurrentCamera (respawn, etc.).
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if model and workspace.CurrentCamera then
			model.Parent = workspace.CurrentCamera
		end
	end)

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, onRenderStep)
end

return ViewmodelController
