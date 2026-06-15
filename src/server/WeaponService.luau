--!strict
-- Module: server/WeaponService
-- Authoritative hitscan (BLUEPRINT.md §10.7, NEW). The client sends only an
-- intent (origin, direction, shotId); the server validates the held weapon,
-- fire-rate, plausibility, then does its OWN raycast from a trusted origin and
-- applies damage. Ammo is mutated solely via AmmoLedger.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local WEAPON = Config.Weapon

local WeaponService = {}

local remotes: any = nil
local holdState: any = nil
local ammo: any = nil

local lastFire: { [Player]: number } = {} -- os.clock() of last accepted shot
local lastFireRequest: { [Player]: number } = {} -- rate-limit backstop
local reloadingUntil: { [Player]: number } = {}
local lastReloadRequest: { [Player]: number } = {}

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function buildRaycastParams(player: Player): RaycastParams
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

local function resolveHumanoid(hitInstance: Instance): (Humanoid?, Player?)
	local model = hitInstance:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local hitPlayer = Players:GetPlayerFromCharacter(model)
			return humanoid, hitPlayer
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function onFireRequest(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	local shotId = (typeof(clientShotId) == "number") and clientShotId or 0

	-- §14.2 rate-limit backstop (under the per-weapon fire rate).
	local now = os.clock()
	local lastReq = lastFireRequest[player]
	if lastReq and (now - lastReq) * 1000 < Config.Security.fireRequestCooldownMs then
		return
	end
	lastFireRequest[player] = now

	-- Held weapon?
	local state = holdState.get(player)
	if state.kind ~= "Weapon" or not state.weaponId then
		remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end
	local weaponId = state.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end

	-- Not mid-reload.
	local reloadEnd = reloadingUntil[player]
	if reloadEnd and now < reloadEnd then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end

	-- Per-weapon fire rate (server timestamp).
	local previous = lastFire[player]
	if previous and (now - previous) < (1 / def.fireRateRps) then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end

	-- Ammo (the sole mutator).
	if not ammo.canFire(player, weaponId) then
		remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end

	-- Validate payload types.
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end
	local claimedOrigin = origin :: Vector3
	local claimedDir = direction :: Vector3
	if claimedDir.Magnitude < 0.001 then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end
	local unitDir = claimedDir.Unit

	-- Plausibility: trusted origin = the head; the claim must be close to it and
	-- aimed within maxAimDeviationDegrees of the real look vector.
	local head = getHead(player)
	if not head then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end
	if (claimedOrigin - head.Position).Magnitude > WEAPON.maxOriginDeviation then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end
	local lookDot = math.clamp(head.CFrame.LookVector:Dot(unitDir), -1, 1)
	local deviation = math.deg(math.acos(lookDot))
	if deviation > WEAPON.maxAimDeviationDegrees then
		remotes.FireResult:FireClient(player, shotId, false, ammo.get(player, weaponId))
		return
	end

	-- Accept the shot: consume a round and stamp the fire time.
	if not ammo.consumeRound(player, weaponId) then
		remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end
	lastFire[player] = now
	local remaining = ammo.get(player, weaponId)

	-- Authoritative raycast from the TRUSTED head origin (enforces LoS / walls /
	-- range — never trusts the client's hit claim).
	local trustedOrigin = head.Position
	local rayLength = def.range + WEAPON.serverRayLengthPadding
	local params = buildRaycastParams(player)
	local result = Workspace:Raycast(trustedOrigin, unitDir * rayLength, params)

	local hitPosition = trustedOrigin + unitDir * rayLength
	if result then
		hitPosition = result.Position
		local humanoid = resolveHumanoid(result.Instance)
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(def.damage)
		end
	end

	remotes.FireResult:FireClient(player, shotId, true, remaining, hitPosition)
	-- Broadcast for other clients' tracers/impacts.
	remotes.ShotFired:FireAllClients(player, trustedOrigin, hitPosition)

	-- TODO(v2: lagcomp) rewind hit characters to the shooter's render time here.
end

local function onReloadRequest(player: Player)
	local now = os.clock()
	local lastReq = lastReloadRequest[player]
	if lastReq and (now - lastReq) * 1000 < Config.Security.reloadRequestCooldownMs then
		return
	end
	lastReloadRequest[player] = now

	local state = holdState.get(player)
	if state.kind ~= "Weapon" or not state.weaponId then
		return
	end
	local weaponId = state.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end
	-- Already full or already reloading.
	if reloadingUntil[player] and now < reloadingUntil[player] then
		return
	end
	if ammo.get(player, weaponId) >= def.maxAmmo then
		return
	end

	reloadingUntil[player] = now + def.reloadTime
	task.delay(def.reloadTime, function()
		-- Still holding the same weapon when the timer elapses?
		local s = holdState.get(player)
		if s.kind ~= "Weapon" or s.weaponId ~= weaponId then
			return
		end
		local newAmmo = ammo.reload(player, weaponId)
		reloadingUntil[player] = nil
		if player.Parent then
			remotes.ReloadResult:FireClient(player, true, newAmmo)
		end
	end)
end

function WeaponService.cleanupPlayer(player: Player)
	lastFire[player] = nil
	lastFireRequest[player] = nil
	reloadingUntil[player] = nil
	lastReloadRequest[player] = nil
end

function WeaponService.init(deps: { remotes: any, holdState: any, ammo: any })
	remotes = deps.remotes
	holdState = deps.holdState
	ammo = deps.ammo

	remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

return WeaponService
