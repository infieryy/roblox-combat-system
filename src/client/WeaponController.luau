--!strict
-- Module: client/WeaponController
-- Client weapon prediction + firing (BLUEPRINT.md §11.5, NEW). Predicts the
-- shot locally (kick/flash/tracer/ammo--) for zero-lag feel, then sends only the
-- intent (origin, direction, clientShotId). Server authority reconciles ammo via
-- FireResult; rejected shots roll the predicted ammo back to the server value.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local ViewmodelController = require(script.Parent.ViewmodelController)

local WEAPON = Config.Weapon

local WeaponController = {}

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local remotes: any = nil
local equipped = false
local weaponId: string? = nil
local predictedAmmo = 0
local maxAmmo = 0
local reloading = false
local mouseDown = false
local lastFireClock = 0
local shotIdCounter = 0

----------------------------------------------------------------------
-- HUD.
----------------------------------------------------------------------

local playerGui = player:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "WeaponHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = playerGui

local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "Ammo"
ammoLabel.AnchorPoint = Vector2.new(1, 1)
ammoLabel.Position = UDim2.new(1, -28, 1, -24)
ammoLabel.Size = UDim2.fromOffset(220, 44)
ammoLabel.BackgroundTransparency = 1
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
ammoLabel.TextSize = 30
ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ammoLabel.TextStrokeTransparency = 0.4
ammoLabel.Text = ""
ammoLabel.Parent = gui

local function refreshHud()
	if not equipped then
		gui.Enabled = false
		return
	end
	gui.Enabled = true
	if reloading then
		ammoLabel.Text = "RELOADING…"
		ammoLabel.TextColor3 = Color3.fromRGB(255, 200, 120)
	else
		ammoLabel.Text = string.format("%d / %d", predictedAmmo, maxAmmo)
		ammoLabel.TextColor3 = (predictedAmmo <= 0) and Color3.fromRGB(255, 110, 110) or Color3.fromRGB(255, 255, 255)
	end
end

----------------------------------------------------------------------
-- Tracer rendering.
----------------------------------------------------------------------

local function renderTracer(fromPos: Vector3, toPos: Vector3)
	local distance = (toPos - fromPos).Magnitude
	if distance < 0.1 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 233, 150)
	beam.Size = Vector3.new(WEAPON.tracerWidth, WEAPON.tracerWidth, distance)
	beam.CFrame = CFrame.lookAt(fromPos, toPos) * CFrame.new(0, 0, -distance / 2)
	beam.Parent = Workspace
	Debris:AddItem(beam, WEAPON.tracerDuration)
end

----------------------------------------------------------------------
-- Firing.
----------------------------------------------------------------------

local function getCamera(): Camera?
	camera = Workspace.CurrentCamera
	return camera
end

local function buildClientRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterDescendantsInstances = filter
	return params
end

local function currentDef()
	return weaponId and ItemRegistry.getWeaponDef(weaponId) or nil
end

local function tryFire()
	if not equipped or reloading or predictedAmmo <= 0 then
		return
	end
	local def = currentDef()
	if not def then
		return
	end
	local now = os.clock()
	if (now - lastFireClock) < (1 / def.fireRateRps) then
		return
	end
	local cam = getCamera()
	if not cam then
		return
	end

	lastFireClock = now
	predictedAmmo -= 1
	refreshHud()

	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector

	-- Local raycast to place the tracer endpoint and impact visual.
	local params = buildClientRaycastParams()
	local result = Workspace:Raycast(origin, direction * def.range, params)
	local endPos = result and result.Position or (origin + direction * def.range)

	-- Predict visuals.
	ViewmodelController.playFireKick()
	renderTracer(ViewmodelController.getMuzzlePosition(), endPos)

	shotIdCounter += 1
	remotes.FireRequest:FireServer(origin, direction, shotIdCounter)
end

----------------------------------------------------------------------
-- Net reconciliation.
----------------------------------------------------------------------

local function onEquipResult(ok: boolean, id: string?, ammo: number?)
	if not ok or not id then
		return
	end
	local def = ItemRegistry.getWeaponDef(id)
	weaponId = id
	equipped = true
	reloading = false
	maxAmmo = def and def.maxAmmo or 0
	predictedAmmo = ammo or maxAmmo
	refreshHud()
end

local function onHoldStateChanged(kind: string)
	if kind ~= "Weapon" then
		equipped = false
		weaponId = nil
		reloading = false
		mouseDown = false
		refreshHud()
	end
end

local function onFireResult(_shotId: number, ok: boolean, ammo: number)
	-- Server is authoritative for ammo; reconcile (handles rejected shots too).
	predictedAmmo = ammo
	if not ok then
		-- Rejected: keep the authoritative count; nothing else to undo cleanly.
	end
	refreshHud()
end

local function onShotFired(shooter: Player, origin: Vector3, hitPosition: Vector3)
	if shooter == player then
		return -- our own tracer was already drawn on prediction
	end
	renderTracer(origin, hitPosition)
end

local function onReloadResult(ok: boolean, ammo: number)
	reloading = false
	if ok then
		predictedAmmo = ammo
	end
	refreshHud()
end

local function tryReload()
	if not equipped or reloading then
		return
	end
	if predictedAmmo >= maxAmmo then
		return
	end
	reloading = true
	refreshHud()
	remotes.ReloadRequest:FireServer()
end

----------------------------------------------------------------------
-- Start.
----------------------------------------------------------------------

function WeaponController.start(remotesTable: any)
	remotes = remotesTable

	remotes.EquipResult.OnClientEvent:Connect(onEquipResult)
	remotes.HoldStateChanged.OnClientEvent:Connect(onHoldStateChanged)
	remotes.FireResult.OnClientEvent:Connect(onFireResult)
	remotes.ShotFired.OnClientEvent:Connect(onShotFired)
	remotes.ReloadResult.OnClientEvent:Connect(onReloadResult)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- Only fire when a weapon is equipped; otherwise left-click is the
			-- prop-grab path owned by InteractionController.
			if equipped then
				mouseDown = true
				tryFire()
			end
		elseif input.KeyCode == Enum.KeyCode.R then
			tryReload()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseDown = false
		end
	end)

	-- Full-auto support: while held and equipped, keep firing at the weapon's
	-- server-allowed rate (semi-auto weapons simply re-trigger per click).
	RunService.Heartbeat:Connect(function()
		if mouseDown and equipped then
			tryFire()
		end
	end)
end

return WeaponController
