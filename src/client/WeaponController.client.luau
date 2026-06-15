--!strict
--[[
	WeaponController (LocalScript)
	------------------------------
	The player-facing combat controller. Responsibilities:
	  * equip a weapon with its number key (1-9), holster with H,
	  * fire with the left mouse button (single or automatic per weapon),
	  * reload with R,
	  * raycast each shot from the SAME first-person camera the pickup system
	    uses, spawn local tracer / impact FX, and apply viewmodel recoil,
	  * keep a predicted ammo count + HUD, reconciled by the server's authoritative
	    FireResult / AmmoUpdate messages.

	Hooks into the dragging system (without touching it):
	  * While HoldState.isHolding() (carrying a picked-up object) ALL combat input
	    is ignored and the equipped weapon is holstered, so you can never shoot
	    while dragging. Dropping the object restores the previously equipped
	    weapon automatically.

	Security: the client NEVER tells the server how much damage to deal or what it
	hit. It only sends the shot origin + per-pellet directions; WeaponService does
	its own authoritative raycast and damage. The local raycast here is purely
	cosmetic (tracers / impact sparks).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")

local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local WeaponRemotes = require(Shared:WaitForChild("WeaponRemotes"))

local CameraController = require(script.Parent:WaitForChild("CameraController"))
local ViewmodelController = require(script.Parent:WaitForChild("ViewmodelController"))
local HoldState = require(script.Parent:WaitForChild("HoldState"))

local LocalPlayer = Players.LocalPlayer
local remotes = WeaponRemotes.get()

type EquipState = {
	name: string,
	def: WeaponConfig.WeaponDefinition,
	magazine: number,
	reserve: number,
	lastFire: number,
	reloading: boolean,
}

local equipped: EquipState? = nil
-- The weapon to restore after a drag ends (so dragging doesn't lose your gun).
local suspendedWeaponName: string? = nil
local fireHeld = false

-- Number-row + keypad keycodes mapped to weapon slots (the "1" key is named
-- "One" in Roblox, so an explicit table is the reliable way to detect it).
local SLOT_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
	[Enum.KeyCode.KeypadFive] = 5,
	[Enum.KeyCode.KeypadSix] = 6,
	[Enum.KeyCode.KeypadSeven] = 7,
	[Enum.KeyCode.KeypadEight] = 8,
	[Enum.KeyCode.KeypadNine] = 9,
}

------------------------------------------------------------------
-- HUD
------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "Ammo"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.new(1, -24, 1, -24)
ammoLabel.Size = UDim2.fromOffset(260, 44)
ammoLabel.BackgroundTransparency = 1
ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
ammoLabel.TextColor3 = Color3.new(1, 1, 1)
ammoLabel.TextStrokeTransparency = 0.4
ammoLabel.TextSize = 30
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.Text = ""
ammoLabel.Visible = false
ammoLabel.Parent = gui

local function updateHud()
	local e = equipped
	if not e then
		ammoLabel.Visible = false
		return
	end
	ammoLabel.Visible = true
	if e.reloading then
		ammoLabel.Text = string.format("%s   reloading…", e.def.DisplayName)
	else
		ammoLabel.Text = string.format("%s   %d / %d", e.def.DisplayName, e.magazine, e.reserve)
	end
end

------------------------------------------------------------------
-- FX (local, cosmetic only)
------------------------------------------------------------------

local function spawnTracer(from: Vector3, to: Vector3)
	local distance = (to - from).Magnitude
	if distance < 0.1 then
		return
	end
	local tracer = Instance.new("Part")
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = Color3.fromRGB(255, 226, 150)
	tracer.Transparency = 0.25
	tracer.Size = Vector3.new(0.05, 0.05, distance)
	tracer.CFrame = CFrame.lookAt(from, to) * CFrame.new(0, 0, -distance / 2)
	tracer.Parent = workspace
	Debris:AddItem(tracer, 0.05)
end

local function spawnImpact(position: Vector3, normal: Vector3)
	local impact = Instance.new("Part")
	impact.Anchored = true
	impact.CanCollide = false
	impact.CanQuery = false
	impact.CanTouch = false
	impact.CastShadow = false
	impact.Material = Enum.Material.Neon
	impact.Color = Color3.fromRGB(255, 200, 120)
	impact.Size = Vector3.new(0.25, 0.25, 0.25)
	impact.CFrame = CFrame.lookAt(position, position + normal)
	impact.Parent = workspace
	Debris:AddItem(impact, 0.06)
end

------------------------------------------------------------------
-- Raycast params (cosmetic local ray)
------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshRayFilter()
	local filter: { Instance } = {}
	if LocalPlayer.Character then
		table.insert(filter, LocalPlayer.Character)
	end
	if workspace.CurrentCamera then
		-- Never let the local ray hit our own viewmodel.
		table.insert(filter, workspace.CurrentCamera)
	end
	rayParams.FilterDescendantsInstances = filter
end

------------------------------------------------------------------
-- Aiming / spread
------------------------------------------------------------------

-- Build a direction perturbed inside a cone of `spreadDegrees` half-angle.
local function spreadDirection(baseDir: Vector3, spreadDegrees: number): Vector3
	if spreadDegrees <= 0 then
		return baseDir
	end
	local maxAngle = math.rad(spreadDegrees)
	-- Random point in a cone around baseDir.
	local angle = math.random() * maxAngle
	local roll = math.random() * math.pi * 2

	-- An arbitrary axis perpendicular to baseDir.
	local up = math.abs(baseDir.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local right = baseDir:Cross(up).Unit
	local realUp = right:Cross(baseDir).Unit

	local tilt = (right * math.cos(roll) + realUp * math.sin(roll)) * math.sin(angle)
	return (baseDir * math.cos(angle) + tilt).Unit
end

------------------------------------------------------------------
-- Firing
------------------------------------------------------------------

local function tryFire()
	local e = equipped
	if not e then
		return
	end
	if HoldState.isHolding() then
		return
	end
	if e.reloading then
		return
	end

	local now = os.clock()
	local interval = WeaponConfig.fireInterval(e.def)
	if now - e.lastFire < interval then
		return
	end

	if e.magazine <= 0 then
		return
	end

	e.lastFire = now
	e.magazine -= 1
	updateHud()

	refreshRayFilter()

	local camCFrame = CameraController.getCFrame()
	local origin = camCFrame.Position
	local baseDir = camCFrame.LookVector
	local muzzle = ViewmodelController.getMuzzlePosition()

	local directions: { Vector3 } = {}
	for _ = 1, math.max(1, e.def.Pellets) do
		local dir = spreadDirection(baseDir, e.def.SpreadDegrees)
		table.insert(directions, dir)

		-- Local cosmetic raycast for the tracer + impact only.
		local result = workspace:Raycast(origin, dir * e.def.Range, rayParams)
		local hitPos = result and result.Position or (origin + dir * e.def.Range)
		spawnTracer(muzzle, hitPos)
		if result then
			spawnImpact(result.Position, result.Normal)
		end
	end

	ViewmodelController.applyRecoil(1)

	-- Server does the authoritative raycast + damage from these inputs.
	remotes.FireRequest:FireServer(e.name, origin, directions)
end

------------------------------------------------------------------
-- Reload
------------------------------------------------------------------

local function tryReload()
	local e = equipped
	if not e or e.reloading then
		return
	end
	if HoldState.isHolding() then
		return
	end
	if e.magazine >= e.def.MagazineSize or e.reserve <= 0 then
		return
	end

	e.reloading = true
	updateHud()

	-- Ask the authoritative server to reload too; it replies with AmmoUpdate.
	remotes.ReloadRequest:FireServer()

	local def = e.def
	task.delay(def.ReloadTime, function()
		-- The equipped weapon may have changed during the reload.
		if equipped ~= e then
			return
		end
		local needed = def.MagazineSize - e.magazine
		local taken = math.min(needed, e.reserve)
		e.magazine += taken
		e.reserve -= taken
		e.reloading = false
		updateHud()
	end)
end

------------------------------------------------------------------
-- Equip / holster
------------------------------------------------------------------

local function holster(notifyServer: boolean)
	if not equipped then
		return
	end
	equipped = nil
	ViewmodelController.unequip()
	updateHud()
	if notifyServer then
		remotes.UnequipRequest:FireServer()
	end
end

local function equip(name: string)
	local def = WeaponConfig.get(name)
	if not def then
		return
	end

	-- Re-pressing the same slot holsters (toggle).
	if equipped and equipped.name == name then
		holster(true)
		return
	end

	-- Can't draw a weapon while carrying an object; remember the request so it
	-- is honoured the moment the object is dropped.
	if HoldState.isHolding() then
		suspendedWeaponName = name
		return
	end

	equipped = {
		name = name,
		def = def,
		magazine = def.MagazineSize,
		reserve = def.ReserveAmmo,
		lastFire = 0,
		reloading = false,
	}
	ViewmodelController.equip(def)
	updateHud()
	remotes.EquipRequest:FireServer(name)
end

------------------------------------------------------------------
-- Drag <-> combat coordination
------------------------------------------------------------------

HoldState.subscribe(function(state)
	if state.holding then
		-- Suspend the current weapon for the duration of the drag.
		if equipped then
			suspendedWeaponName = equipped.name
			holster(true)
		end
	else
		-- Drag finished: restore whatever was suspended.
		local restore = suspendedWeaponName
		suspendedWeaponName = nil
		if restore then
			equip(restore)
		end
	end
end)

------------------------------------------------------------------
-- Input
------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		fireHeld = true
		tryFire()
		return
	end

	if input.KeyCode == Enum.KeyCode[WeaponConfig.HolsterKey] then
		holster(true)
		return
	end

	if input.KeyCode == Enum.KeyCode[WeaponConfig.ReloadKey] then
		-- R also rotates a held object; that path is owned by the pickup system
		-- and only active while holding (when combat is suspended), so reloading
		-- here is safe and never conflicts.
		tryReload()
		return
	end

	-- Number keys 1-9 select the weapon bound to that slot.
	local slot = SLOT_KEYS[input.KeyCode]
	if slot then
		local weaponName = WeaponConfig.weaponForSlot(slot)
		if weaponName then
			equip(weaponName)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		fireHeld = false
	end
end)

-- Automatic fire: while the button is held and the weapon is automatic, keep
-- firing at the weapon's cadence (tryFire self-limits via the fire interval).
RunService.Heartbeat:Connect(function()
	if not fireHeld then
		return
	end
	local e = equipped
	if e and e.def.Automatic then
		tryFire()
	end
end)

------------------------------------------------------------------
-- Authoritative reconciliation from the server
------------------------------------------------------------------

remotes.EquipGranted.OnClientEvent:Connect(function(name: string, magazine: number, reserve: number)
	local e = equipped
	if e and e.name == name and typeof(magazine) == "number" and typeof(reserve) == "number" then
		e.magazine = magazine
		e.reserve = reserve
		updateHud()
	end
end)

remotes.FireResult.OnClientEvent:Connect(function(magazine: number, reserve: number, _accepted: boolean)
	local e = equipped
	if e and typeof(magazine) == "number" and typeof(reserve) == "number" then
		-- Trust the server's count (covers rejected shots / desync).
		e.magazine = magazine
		e.reserve = reserve
		updateHud()
	end
end)

remotes.AmmoUpdate.OnClientEvent:Connect(function(magazine: number, reserve: number)
	local e = equipped
	if e and typeof(magazine) == "number" and typeof(reserve) == "number" then
		e.magazine = magazine
		e.reserve = reserve
		e.reloading = false
		updateHud()
	end
end)

remotes.HitConfirm.OnClientEvent:Connect(function(position: Vector3, _hitHumanoid: boolean)
	if typeof(position) == "Vector3" then
		spawnImpact(position, Vector3.yAxis)
	end
end)

------------------------------------------------------------------
-- Boot
------------------------------------------------------------------

ViewmodelController.start()
updateHud()
