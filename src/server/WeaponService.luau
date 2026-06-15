--!strict
--[[
	WeaponService (ModuleScript)
	----------------------------
	The authoritative brain of the combat layer, mirroring PickupService:
	  * tracks each player's equipped weapon + ammo (magazine / reserve),
	  * validates every fire request (fire-rate, ammo, origin sanity, range),
	  * performs its OWN raycast for each pellet and applies damage — the client
	    never gets to say what it hit or how much damage to deal,
	  * broadcasts confirmed hits for shared FX,
	  * refuses to fire / equip while the player is carrying a picked-up object
	    (queried from PickupService) so the two systems can never overlap,
	  * cleans up on death / respawn / disconnect.

	Anti-exploit model:
	  The client sends only { weaponName, origin, directions }. The server checks
	  the origin is near the player's actual head, clamps the pellet count to the
	  weapon's spec, enforces the fire interval, decrements server-side ammo, and
	  raycasts from the origin along each direction (ignoring the shooter's own
	  character + held objects via collision groups). Damage is derived purely
	  from the server's WeaponConfig.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("PickupSystem")

local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local WeaponRemotes = require(Shared:WaitForChild("WeaponRemotes"))

local PickupService = require(script.Parent:WaitForChild("PickupService"))

local WeaponService = {}

type LoadoutState = {
	name: string,
	def: WeaponConfig.WeaponDefinition,
	magazine: number,
	reserve: number,
	lastFire: number,
	reloading: boolean,
}

local loadouts: { [Player]: LoadoutState } = {}
local remotes: WeaponRemotes.RemoteSet

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
end

local function isAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Build raycast params that ignore the shooter's own character (so they never
-- shoot themselves) and the pickup collision groups (held objects / characters
-- are handled separately; we still want to hit other players, so we exclude only
-- the shooter explicitly rather than the whole character group).
local function buildRayParams(shooter: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local filter: { Instance } = {}
	if shooter.Character then
		table.insert(filter, shooter.Character)
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- Walk up from a hit part to find the Humanoid it belongs to (and the owning
-- player, if any). Returns nil if the hit was not a character.
local function resolveHumanoid(hit: Instance?): (Humanoid?, Player?)
	local current = hit
	while current and current ~= workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return humanoid, Players:GetPlayerFromCharacter(current)
			end
		end
		current = current.Parent
	end
	return nil, nil
end

local function fireResult(player: Player, accepted: boolean)
	local state = loadouts[player]
	if not state then
		return
	end
	remotes.FireResult:FireClient(player, state.magazine, state.reserve, accepted)
end

------------------------------------------------------------------
-- Equip / unequip
------------------------------------------------------------------

local function onEquipRequest(player: Player, weaponName: unknown)
	if typeof(weaponName) ~= "string" then
		return
	end
	local def = WeaponConfig.get(weaponName)
	if not def then
		return
	end
	if not isAlive(player) then
		return
	end
	-- Cannot draw a weapon while carrying an object.
	if PickupService.isHolding(player) then
		return
	end

	local existing = loadouts[player]
	if existing and existing.name == weaponName then
		-- Already equipped: just resync ammo.
		remotes.EquipGranted:FireClient(player, weaponName, existing.magazine, existing.reserve)
		return
	end

	local state: LoadoutState = {
		name = weaponName,
		def = def,
		magazine = def.MagazineSize,
		reserve = def.ReserveAmmo,
		lastFire = 0,
		reloading = false,
	}
	loadouts[player] = state
	remotes.EquipGranted:FireClient(player, weaponName, state.magazine, state.reserve)
end

local function unequip(player: Player, notifyClient: boolean)
	if not loadouts[player] then
		return
	end
	loadouts[player] = nil
	if notifyClient then
		remotes.UnequipGranted:FireClient(player)
	end
end

------------------------------------------------------------------
-- Fire
------------------------------------------------------------------

local function onFireRequest(player: Player, weaponName: unknown, origin: unknown, directions: unknown)
	local state = loadouts[player]
	if not state then
		return
	end
	-- The reported weapon must match the equipped one.
	if typeof(weaponName) ~= "string" or weaponName ~= state.name then
		return
	end
	if typeof(origin) ~= "Vector3" or typeof(directions) ~= "table" then
		return
	end
	if not isAlive(player) then
		return
	end
	if PickupService.isHolding(player) then
		fireResult(player, false)
		return
	end
	if state.reloading then
		fireResult(player, false)
		return
	end

	local def = state.def
	local now = os.clock()
	-- Fire-rate gate with a little latency slack.
	if now - state.lastFire < WeaponConfig.fireInterval(def) - WeaponConfig.FireRateTolerance then
		fireResult(player, false)
		return
	end

	if state.magazine <= 0 then
		fireResult(player, false)
		return
	end

	-- Origin must be near the player's real head (anti-teleport-shot). 8 studs of
	-- slack covers head/camera offset plus a little latency.
	local head = getHead(player)
	if not head then
		fireResult(player, false)
		return
	end
	local originVec = origin :: Vector3
	if (originVec - head.Position).Magnitude > 8 then
		-- Origin too far from the head; reject without consuming ammo.
		fireResult(player, false)
		return
	end

	state.lastFire = now
	state.magazine -= 1

	local params = buildRayParams(player)
	local maxRange = def.Range + WeaponConfig.RangeTolerance
	local dirList = directions :: { unknown }
	local pelletBudget = math.max(1, def.Pellets)
	local processed = 0

	-- Track damage per humanoid so multi-pellet weapons apply one combined hit
	-- (and so a headshot multiplier is applied per pellet that hits the head).
	local damageByHumanoid: { [Humanoid]: number } = {}
	local hitPositions: { Vector3 } = {}

	for _, rawDir in dirList do
		processed += 1
		if processed > pelletBudget then
			break
		end
		if typeof(rawDir) ~= "Vector3" then
			continue
		end
		local dir = (rawDir :: Vector3)
		if dir.Magnitude < 0.001 then
			continue
		end
		dir = dir.Unit

		local result = workspace:Raycast(originVec, dir * maxRange, params)
		if result then
			local humanoid, _victimPlayer = resolveHumanoid(result.Instance)
			if humanoid and humanoid.Health > 0 then
				local isHead = result.Instance.Name == "Head"
				local damage = def.Damage * (isHead and def.HeadshotMultiplier or 1)
				damageByHumanoid[humanoid] = (damageByHumanoid[humanoid] or 0) + damage
			end
			table.insert(hitPositions, result.Position)
		end
	end

	for humanoid, damage in damageByHumanoid do
		humanoid:TakeDamage(damage)
	end

	-- Broadcast confirmed impacts for shared FX (hit markers / sparks).
	for _, pos in hitPositions do
		remotes.HitConfirm:FireAllClients(pos, true)
	end

	fireResult(player, true)
end

------------------------------------------------------------------
-- Reload (authoritative)
------------------------------------------------------------------

local function onReloadRequest(player: Player)
	local state = loadouts[player]
	if not state or state.reloading then
		return
	end
	if not isAlive(player) then
		return
	end
	if PickupService.isHolding(player) then
		return
	end
	local def = state.def
	if state.magazine >= def.MagazineSize or state.reserve <= 0 then
		return
	end

	state.reloading = true

	task.delay(def.ReloadTime, function()
		-- The loadout may have changed (re-equip, death, disconnect) meanwhile.
		if loadouts[player] ~= state or not state.reloading then
			return
		end
		local needed = def.MagazineSize - state.magazine
		local taken = math.min(needed, state.reserve)
		state.magazine += taken
		state.reserve -= taken
		state.reloading = false
		remotes.AmmoUpdate:FireClient(player, state.magazine, state.reserve)
	end)
end

------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function()
		-- Respawn clears the loadout; the client re-equips if it wants to.
		unequip(player, false)
	end)
end

local function onPlayerRemoving(player: Player)
	loadouts[player] = nil
end

function WeaponService.start()
	remotes = WeaponRemotes.get()

	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotes.UnequipRequest.OnServerEvent:Connect(function(player)
		unequip(player, true)
	end)
	remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	-- Safety net: if a player somehow ends up holding an object while a weapon is
	-- still equipped server-side, drop the weapon to keep the states exclusive.
	RunService.Heartbeat:Connect(function()
		for player in loadouts do
			if PickupService.isHolding(player) then
				unequip(player, true)
			end
		end
	end)
end

return WeaponService
