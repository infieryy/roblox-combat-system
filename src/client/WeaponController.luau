--!strict
-- Module: WeaponController  (client-side)
-- Manages weapon equip prediction, client-side fire prediction, ammo HUD, and reload.
-- Blueprint §11.5.
--
-- Input ownership:
--   LMB while weapon equipped    → fire
--   LMB while no weapon          → InteractionController handles (drag)
--   E while looking at weapon    → InteractionController fires EquipRequest
--   [1]/[2] keybinds             → select weapon to equip (if in sight range)
--   R key                        → reload
--   Q key / weapon taken away    → server sends HoldStateChanged("None")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local player = Players.LocalPlayer

-- -------------------------------------------------------------------------
-- WeaponController class
-- -------------------------------------------------------------------------

local WeaponController = {}
WeaponController.__index = WeaponController

type RemotesInterface = {
	EquipRequest: RemoteEvent,
	EquipResult: RemoteEvent,
	UnequipRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ShotFired: RemoteEvent,
	ReloadRequest: RemoteEvent,
	ReloadResult: RemoteEvent,
}

type ViewmodelInterface = {
	equip: (self: any, weaponId: string) -> (),
	unequip: (self: any) -> (),
	getMuzzlePosition: (self: any) -> Vector3?,
	playFireKick: (self: any) -> (),
}

type DragControllerInterface = {
	isDragging: (self: any) -> boolean,
}

type InteractionInterface = {
	setAmmoDisplay: (ammo: number?, maxAmmo: number?) -> (),
}

function WeaponController.new(
	remotes: RemotesInterface,
	dragController: DragControllerInterface,
	viewmodelController: ViewmodelInterface,
	interactionController: InteractionInterface
)
	local self = setmetatable({}, WeaponController)
	self.remotes = remotes
	self.dragController = dragController
	self.viewmodelController = viewmodelController
	self.interactionController = interactionController

	self._currentWeaponId = nil :: string?
	self._predictedAmmo = 0
	self._lastShotAt = 0
	self._shotCounter = 0
	self._reloading = false
	self._connections = {}

	return self
end

-- -------------------------------------------------------------------------
-- Internal helpers
-- -------------------------------------------------------------------------

function WeaponController:_updateAmmoHUD()
	local weaponId = self._currentWeaponId
	if weaponId then
		local def = ItemRegistry.getWeaponDef(weaponId)
		local maxAmmo = def and def.maxAmmo or 0
		self.interactionController.setAmmoDisplay(self._predictedAmmo, maxAmmo)
	else
		-- nil → hide the HUD
		self.interactionController.setAmmoDisplay(nil, nil)
	end
end

function WeaponController:_onEquipSuccess(weaponId: string, ammo: number)
	self._currentWeaponId = weaponId
	self._predictedAmmo = ammo
	self._reloading = false
	self.viewmodelController:equip(weaponId)
	self:_updateAmmoHUD()
end

function WeaponController:_onUnequip()
	self._currentWeaponId = nil
	self._predictedAmmo = 0
	self._reloading = false
	self.viewmodelController:unequip()
	self:_updateAmmoHUD()
end

-- -------------------------------------------------------------------------
-- Fire
-- -------------------------------------------------------------------------

function WeaponController:_attemptFire()
	local weaponId = self._currentWeaponId
	if not weaponId then return end
	if self.dragController:isDragging() then return end
	if self._reloading then return end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	local now = os.clock()
	local cooldown = 1 / def.fireRateRps
	if now - self._lastShotAt < cooldown then return end

	if self._predictedAmmo <= 0 then
		-- Out of ammo: trigger reload automatically.
		self:_requestReload()
		return
	end

	self._lastShotAt = now
	self._shotCounter += 1
	local shotId = self._shotCounter

	-- Client-side prediction: decrement ammo, show kick.
	self._predictedAmmo -= 1
	self:_updateAmmoHUD()
	self.viewmodelController:playFireKick()

	-- Build ray from camera centre.
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local origin = cam.CFrame.Position
	local direction = cam.CFrame.LookVector

	-- Send to server.
	self.remotes.FireRequest:FireServer(origin, direction, shotId)
end

-- -------------------------------------------------------------------------
-- Reload
-- -------------------------------------------------------------------------

function WeaponController:_requestReload()
	if not self._currentWeaponId then return end
	if self._reloading then return end
	local def = ItemRegistry.getWeaponDef(self._currentWeaponId)
	if not def then return end
	if self._predictedAmmo >= def.maxAmmo then return end

	self._reloading = true
	self.remotes.ReloadRequest:FireServer()
end

-- -------------------------------------------------------------------------
-- start()
-- -------------------------------------------------------------------------

function WeaponController:start()
	-- EquipResult: server confirms equip or rejects.
	table.insert(self._connections,
		self.remotes.EquipResult.OnClientEvent:Connect(function(ok: boolean, weaponId: unknown, ammo: unknown)
			if ok then
				if typeof(weaponId) == "string" and typeof(ammo) == "number" then
					self:_onEquipSuccess(weaponId :: string, ammo :: number)
				end
			end
		end)
	)

	-- HoldStateChanged: authoritative hold state (overrides prediction).
	table.insert(self._connections,
		self.remotes.HoldStateChanged.OnClientEvent:Connect(function(kind: string, instance: unknown)
			if kind == "None" then
				self:_onUnequip()
			elseif kind == "Weapon" then
				-- If we already equipped this weapon locally (predicted), no-op.
				-- If it's a server-forced equip change (e.g. another system), sync.
			elseif kind == "Prop" then
				-- Holding a prop means no weapon; ensure viewmodel is hidden.
				self:_onUnequip()
			end
		end)
	)

	-- FireResult: reconcile client prediction with server truth.
	table.insert(self._connections,
		self.remotes.FireResult.OnClientEvent:Connect(function(
			clientShotId: number,
			ok: boolean,
			ammo: number,
			hitPosition: Vector3?
		)
			-- Always trust server ammo.
			self._predictedAmmo = ammo
			self:_updateAmmoHUD()

			if not ok then
				-- Server rejected the shot (rate limit, wall, no ammo);
				-- visuals already played but ammo is now reconciled.
				warn("[WeaponController] Shot rejected by server, shotId:", clientShotId)
			end
		end)
	)

	-- ShotFired: other players' shots — render tracer/impact effects.
	table.insert(self._connections,
		self.remotes.ShotFired.OnClientEvent:Connect(function(
			shooter: Player,
			origin: Vector3,
			hitPosition: Vector3?
		)
			-- TODO(v2): spawn tracer beam and impact particles for other players' shots.
			local _s, _o, _h = shooter, origin, hitPosition
		end)
	)

	-- ReloadResult: server confirms reload and gives authoritative ammo count.
	table.insert(self._connections,
		self.remotes.ReloadResult.OnClientEvent:Connect(function(ok: boolean, ammo: number)
			self._reloading = false
			if ok then
				self._predictedAmmo = ammo
				self:_updateAmmoHUD()
			end
		end)
	)

	-- Input bindings.
	table.insert(self._connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then return end

			-- LMB fires if weapon is equipped.
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				if self._currentWeaponId then
					self:_attemptFire()
				end
				return
			end

			-- R → reload.
			if input.KeyCode == Enum.KeyCode.R then
				self:_requestReload()
				return
			end

			-- Q → unequip.
			if input.KeyCode == Enum.KeyCode.Q then
				if self._currentWeaponId then
					self.remotes.UnequipRequest:FireServer()
				end
				return
			end
		end)
	)

	-- Auto-fire on held LMB (held mouse = repeat fire for full-auto weapons).
	table.insert(self._connections,
		RunService.Heartbeat:Connect(function()
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				if self._currentWeaponId then
					self:_attemptFire()
				end
			end
		end)
	)
end

function WeaponController:destroy()
	for _, c in self._connections do c:Disconnect() end
	self._connections = {}
end

return WeaponController
