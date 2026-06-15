--!strict
--[[
	WeaponService  (server/WeaponService.luau → ServerScriptService.Server.WeaponService)
	---------------------------------------------------------------------------------------
	Handles FireRequest and ReloadRequest. New system — hitscan only.

	Fire pipeline (onFire):
	  1. Rate-limit (fireRequestCooldownMs).
	  2. PlayerHoldState.get is Weapon; resolve weaponId/def.
	  3. Per-weapon fire-rate check (server timestamp ≥ 1/def.fireRateRps).
	  4. AmmoLedger.canFire → consumeRound; else FireResult(id, false, 0).
	  5. Plausibility: origin near head; direction within maxAimDeviationDegrees.
	  6. Authoritative raycast from server's known head origin along direction,
	     length def.range + serverRayLengthPadding, filter excluding shooter.
	  7. Damage humanoid if hit; FireResult(id, true, ammo, hitPos) + ShotFired.

	-- TODO(v2: lagcomp) anchor: lag-compensation rewind would go between steps
	  5 and 6 — rewind hit-testable character positions to (serverTime - latency)
	  before casting, then restore. Not implemented in v1.
]]

local Players  = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config          = require(Shared:WaitForChild("Config"))
local ItemRegistry    = require(Shared:WaitForChild("ItemRegistry"))
local GeometryUtil    = require(Shared:WaitForChild("GeometryUtil"))
local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger      = require(script.Parent.AmmoLedger)

local function getRemotes()
	return require(script.Parent.Remotes).get()
end

local WeaponService = {}

-- Per-player rate-limit and fire-rate enforcement.
local lastFireRequestTime: { [Player]: number } = {}
local lastFireTime:        { [Player]: number } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then return nil end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head :: BasePart end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then return root :: BasePart end
	return nil
end

-- Build a raycast filter that excludes the shooter's character and their
-- held weapon (so you can't shoot yourself).
local function buildRayFilter(player: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local filter: { Instance } = {}
	local character = player.Character
	if character then
		table.insert(filter, character)
	end
	-- Also exclude the held weapon model if any.
	local holdState = PlayerHoldState.get(player)
	if holdState.kind == "Weapon" and holdState.instance then
		table.insert(filter, holdState.instance)
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Fire handler
-- ─────────────────────────────────────────────────────────────────────────────

local function onFire(
	player: Player,
	rawOrigin: unknown,
	rawDirection: unknown,
	rawClientShotId: unknown
)
	local remotes = getRemotes()

	-- ── 1. Flood-guard ────────────────────────────────────────────────────
	local now = os.clock()
	local lastReq = lastFireRequestTime[player] or 0
	if (now - lastReq) * 1000 < Config.Security.fireRequestCooldownMs then
		return
	end
	lastFireRequestTime[player] = now

	-- Type guards.
	if typeof(rawOrigin) ~= "Vector3" or typeof(rawDirection) ~= "Vector3" then
		return
	end
	if typeof(rawClientShotId) ~= "number" then
		return
	end
	local origin      = rawOrigin :: Vector3
	local direction   = rawDirection :: Vector3
	local clientShotId = rawClientShotId :: number

	-- direction must be a unit vector (within tolerance).
	if math.abs(direction.Magnitude - 1) > 0.05 then
		return
	end

	-- ── 2. Hold state validation ──────────────────────────────────────────
	local holdState = PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end
	local weaponId = holdState.weaponId
	if not weaponId then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	-- ── 3. Per-weapon fire-rate enforcement ───────────────────────────────
	local minInterval = 1 / def.fireRateRps
	local lastFire = lastFireTime[player] or 0
	if (now - lastFire) < minInterval - 0.05 then -- 50ms tolerance for latency
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end
	lastFireTime[player] = now

	-- ── 4. Ammo check ─────────────────────────────────────────────────────
	if not AmmoLedger.canFire(player, weaponId) then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	-- ── 5. Plausibility checks ────────────────────────────────────────────
	local head = getHead(player)
	if not head then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	-- Origin must be near the server's known head position.
	if (origin - head.Position).Magnitude > Config.Weapon.maxOriginDeviation then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	-- Direction must be within maxAimDeviationDegrees of the character's look direction.
	-- We use the HumanoidRootPart look vector as a loose sanity bound (the camera
	-- can pitch freely, so we use a wide angle).
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local characterLook = hrp.CFrame.LookVector
		local dot = direction:Dot(characterLook)
		local maxDot = math.cos(math.rad(Config.Weapon.maxAimDeviationDegrees))
		if dot < maxDot then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
			return
		end
	end

	-- ── 6. Authoritative raycast from trusted origin ──────────────────────
	-- Use the server's known head position, not the client's claimed origin.
	-- TODO(v2: lagcomp): rewind world state to (serverTime - playerLatency) here.
	local trustedOrigin = head.Position
	local rayLength     = def.range + Config.Weapon.serverRayLengthPadding
	local rayParams     = buildRayFilter(player)

	local result = Workspace:Raycast(trustedOrigin, direction * rayLength, rayParams)

	AmmoLedger.consumeRound(player, weaponId)
	local newAmmo = AmmoLedger.get(player, weaponId)

	-- ── 7. Apply damage and broadcast ────────────────────────────────────
	local hitPosition: Vector3? = nil
	if result then
		hitPosition = result.Position

		-- Find the humanoid in the hit ancestry.
		local hit = result.Instance
		local humanoid: Humanoid? = nil
		local node: Instance? = hit
		while node and node ~= Workspace do
			local h = (node :: Model):FindFirstChildOfClass("Humanoid")
			if h then
				humanoid = h :: Humanoid
				break
			end
			node = node.Parent
		end

		if humanoid and humanoid.Health > 0 then
			-- Verify we are not damaging the shooter.
			local victimPlayer = Players:GetPlayerFromCharacter(humanoid.Parent :: Model)
			if victimPlayer ~= player then
				humanoid:TakeDamage(def.damage)
			end
		end

		remotes.ShotFired:FireAllClients(player, trustedOrigin, hitPosition)
	end

	remotes.FireResult:FireClient(player, clientShotId, true, newAmmo, hitPosition)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Reload handler
-- ─────────────────────────────────────────────────────────────────────────────

local reloadingPlayers: { [Player]: boolean } = {}

local function onReload(player: Player)
	if reloadingPlayers[player] then
		return
	end

	local holdState = PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" or not holdState.weaponId then
		getRemotes().ReloadResult:FireClient(player, false, 0)
		return
	end
	local weaponId = holdState.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		getRemotes().ReloadResult:FireClient(player, false, 0)
		return
	end

	reloadingPlayers[player] = true
	task.delay(def.reloadTime, function()
		reloadingPlayers[player] = nil :: any
		-- Verify they still hold the same weapon.
		local currentState = PlayerHoldState.get(player)
		if currentState.kind == "Weapon" and currentState.weaponId == weaponId then
			local newAmmo = AmmoLedger.reload(player, weaponId)
			if player.Parent then
				getRemotes().ReloadResult:FireClient(player, true, newAmmo)
			end
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function WeaponService.start()
	local remotes = getRemotes()
	remotes.FireRequest.OnServerEvent:Connect(onFire)
	remotes.ReloadRequest.OnServerEvent:Connect(onReload)
end

function WeaponService.onPlayerRemoving(player: Player)
	lastFireRequestTime[player] = nil :: any
	lastFireTime[player]        = nil :: any
	reloadingPlayers[player]    = nil :: any
end

return WeaponService
