local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local CombatRemotes = require(CombatFolder:WaitForChild("CombatRemotes"))
local WeaponDefinitions = require(CombatFolder:WaitForChild("WeaponDefinitions"))

type PlayerWeaponState = {
	equippedWeaponId: string?,
	ammoByWeapon: { [string]: number },
	lastShotAt: number,
	isReloading: boolean,
	reloadWeaponId: string?,
	reloadRequestToken: number,
	draggingWeaponId: string?,
	lastDragPosition: Vector3?,
}

local playerStates: { [Player]: PlayerWeaponState } = {}

local dragActionRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.DragAction, true)
local equipWeaponRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.EquipWeapon, true)
local unequipWeaponRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.UnequipWeapon, true)
local fireWeaponRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.FireWeapon, true)
local reloadWeaponRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.ReloadWeapon, true)
local weaponStateRemote = CombatRemotes.getEvent(CombatRemotes.EVENTS.WeaponState, true)

local function buildDefaultAmmoState(): { [string]: number }
	local ammoByWeapon = {}
	for weaponId, definition in WeaponDefinitions.ById do
		ammoByWeapon[weaponId] = definition.magazineSize
	end
	return ammoByWeapon
end

local function serializeState(state: PlayerWeaponState, reason: string): { [string]: any }
	return {
		reason = reason,
		equippedWeaponId = state.equippedWeaponId,
		ammoByWeapon = state.ammoByWeapon,
		isReloading = state.isReloading,
		reloadWeaponId = state.reloadWeaponId,
		draggingWeaponId = state.draggingWeaponId,
		lastDragPosition = state.lastDragPosition,
	}
end

local function getOrCreateState(player: Player): PlayerWeaponState
	local existing = playerStates[player]
	if existing then
		return existing
	end

	local created: PlayerWeaponState = {
		equippedWeaponId = nil,
		ammoByWeapon = buildDefaultAmmoState(),
		lastShotAt = 0,
		isReloading = false,
		reloadWeaponId = nil,
		reloadRequestToken = 0,
		draggingWeaponId = nil,
		lastDragPosition = nil,
	}
	playerStates[player] = created
	return created
end

local function sendState(player: Player, reason: string)
	local state = getOrCreateState(player)
	weaponStateRemote:FireClient(player, serializeState(state, reason))
end

local function setEquippedWeapon(player: Player, state: PlayerWeaponState, weaponId: string, reason: string)
	state.equippedWeaponId = weaponId
	if state.ammoByWeapon[weaponId] == nil then
		state.ammoByWeapon[weaponId] = WeaponDefinitions.get(weaponId).magazineSize
	end
	sendState(player, reason)
end

local function startReload(player: Player, state: PlayerWeaponState, weaponId: string)
	local weapon = WeaponDefinitions.get(weaponId)
	if weapon.reloadDuration <= 0 then
		return
	end

	state.isReloading = true
	state.reloadWeaponId = weaponId
	state.reloadRequestToken += 1
	local activeToken = state.reloadRequestToken

	sendState(player, "reload_started")

	task.delay(weapon.reloadDuration, function()
		local current = playerStates[player]
		if not current then
			return
		end

		if current.reloadRequestToken ~= activeToken then
			return
		end

		if not current.isReloading or current.reloadWeaponId ~= weaponId then
			return
		end

		current.ammoByWeapon[weaponId] = weapon.magazineSize
		current.isReloading = false
		current.reloadWeaponId = nil
		sendState(player, "reload_finished")
	end)
end

local function canFireNow(state: PlayerWeaponState, weaponId: string): boolean
	local weapon = WeaponDefinitions.get(weaponId)
	local now = os.clock()
	local minimumDelay = 1 / weapon.fireRate
	return (now - state.lastShotAt) >= minimumDelay
end

local function consumeAmmoIfNeeded(state: PlayerWeaponState, weaponId: string)
	local weapon = WeaponDefinitions.get(weaponId)

	-- Melee-like weapons do not consume ammo per swing.
	if weapon.reloadDuration <= 0 and weapon.magazineSize == 1 then
		return
	end

	local currentAmmo = state.ammoByWeapon[weaponId] or weapon.magazineSize
	state.ammoByWeapon[weaponId] = math.max(0, currentAmmo - 1)
end

local function ensureAmmoForWeapon(state: PlayerWeaponState, weaponId: string): number
	local weapon = WeaponDefinitions.get(weaponId)
	local currentAmmo = state.ammoByWeapon[weaponId]
	if currentAmmo == nil then
		currentAmmo = weapon.magazineSize
		state.ammoByWeapon[weaponId] = currentAmmo
	end
	return currentAmmo
end

Players.PlayerAdded:Connect(function(player)
	getOrCreateState(player)
	sendState(player, "initial_sync")
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
end)

equipWeaponRemote.OnServerEvent:Connect(function(player: Player, weaponId: any)
	if typeof(weaponId) ~= "string" then
		return
	end
	if not WeaponDefinitions.exists(weaponId) then
		return
	end

	local state = getOrCreateState(player)
	if state.isReloading then
		state.isReloading = false
		state.reloadWeaponId = nil
		state.reloadRequestToken += 1
	end

	setEquippedWeapon(player, state, weaponId, "equip")
end)

unequipWeaponRemote.OnServerEvent:Connect(function(player: Player)
	local state = getOrCreateState(player)
	state.equippedWeaponId = nil
	state.draggingWeaponId = nil
	state.lastDragPosition = nil
	if state.isReloading then
		state.isReloading = false
		state.reloadWeaponId = nil
		state.reloadRequestToken += 1
	end
	sendState(player, "unequip")
end)

reloadWeaponRemote.OnServerEvent:Connect(function(player: Player)
	local state = getOrCreateState(player)
	local weaponId = state.equippedWeaponId
	if not weaponId then
		return
	end

	if state.isReloading then
		return
	end

	local weapon = WeaponDefinitions.get(weaponId)
	if weapon.reloadDuration <= 0 then
		return
	end

	local currentAmmo = ensureAmmoForWeapon(state, weaponId)
	if currentAmmo >= weapon.magazineSize then
		return
	end

	startReload(player, state, weaponId)
end)

fireWeaponRemote.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local weaponId = payload.weaponId
	if typeof(weaponId) ~= "string" or not WeaponDefinitions.exists(weaponId) then
		return
	end

	local state = getOrCreateState(player)
	if state.equippedWeaponId ~= weaponId then
		return
	end

	if state.isReloading then
		return
	end

	if not canFireNow(state, weaponId) then
		return
	end

	local currentAmmo = ensureAmmoForWeapon(state, weaponId)
	if currentAmmo <= 0 then
		sendState(player, "dry_fire")
		return
	end

	state.lastShotAt = os.clock()
	consumeAmmoIfNeeded(state, weaponId)

	local definition = WeaponDefinitions.get(weaponId)
	local origin = payload.origin
	local direction = payload.direction
	if typeof(origin) == "Vector3" and typeof(direction) == "Vector3" then
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = { player.Character }
		local result = workspace:Raycast(origin, direction.Unit * definition.range, raycastParams)
		if result and result.Instance then
			local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
			if hitModel then
				local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid:TakeDamage(definition.damage)
				end
			end
		end
	end

	sendState(player, "fired")
end)

dragActionRemote.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local state = getOrCreateState(player)

	if action == "begin" then
		local weaponId = payload.weaponId
		if typeof(weaponId) == "string" and WeaponDefinitions.exists(weaponId) then
			state.draggingWeaponId = weaponId
			sendState(player, "drag_begin")
		end
		return
	end

	if action == "update" then
		if typeof(payload.worldPosition) == "Vector3" then
			state.lastDragPosition = payload.worldPosition
		end
		return
	end

	if action == "end" then
		local weaponId = payload.weaponId
		state.draggingWeaponId = nil
		state.lastDragPosition = nil

		local shouldEquip = payload.shouldEquip == true
		if shouldEquip and typeof(weaponId) == "string" and WeaponDefinitions.exists(weaponId) then
			setEquippedWeapon(player, state, weaponId, "drag_equip")
		else
			sendState(player, "drag_end")
		end
	end
end)
