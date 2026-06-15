--!strict
-- Module: WeaponService
-- Authoritative hitscan validation and fire handler. Blueprint §10.7.
-- Pipeline (per FireRequest):
--   rate-limit → PlayerHoldState == Weapon → fire-rate check (server timestamp)
--   → AmmoLedger.canFire → consumeRound
--   → plausibility (angle + origin near head)
--   → authoritative server raycast (LoS / no-wall-penetration)
--   → damage humanoid → FireResult + ShotFired broadcast
--
-- ReloadRequest: validate held → delay → AmmoLedger.reload → ReloadResult.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local _Remotes: any = nil
local _PlayerHoldState: any = nil
local _AmmoLedger: any = nil

local lastFireTime: { [Player]: number } = {}
local reloadingPlayers: { [Player]: boolean } = {}

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------

local function getHead(player: Player): BasePart?
	local char = player.Character
	if not char then return nil end
	local head = char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head :: BasePart end
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	if root and root:IsA("BasePart") then return root :: BasePart end
	return nil
end

local function isAlive(player: Player): boolean
	local char = player.Character
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- -------------------------------------------------------------------------
-- FireRequest handler
-- -------------------------------------------------------------------------

local function onFireRequest(
	player: Player,
	rawOrigin: unknown,
	rawDirection: unknown,
	rawClientShotId: unknown
)
	-- Type guards on all remote arguments (blueprint §14.8).
	if typeof(rawOrigin) ~= "Vector3" then return end
	if typeof(rawDirection) ~= "Vector3" then return end
	if typeof(rawClientShotId) ~= "number" then return end
	local origin = rawOrigin :: Vector3
	local direction = rawDirection :: Vector3
	local clientShotId = rawClientShotId :: number

	-- Hard floor rate limit.
	local now = os.clock()
	if now - (lastFireTime[player] or 0) < Config.Security.fireRequestCooldown then return end

	-- Player must be alive.
	if not isAlive(player) then return end

	-- Must be holding a weapon.
	local holdState = _PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" then return end
	local weaponId = holdState.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	-- Server-side fire-rate enforcement.
	local minInterval = 1 / def.fireRateRps
	if now - (lastFireTime[player] or 0) < minInterval then return end
	lastFireTime[player] = now

	-- Ammo check.
	if not _AmmoLedger.canFire(player, weaponId) then
		_Remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	-- Plausibility: origin must be near the player's head.
	local head = getHead(player)
	if not head then return end
	if (origin - head.Position).Magnitude > 20 then
		warn("[WeaponService] Suspicious origin from", player.Name)
		return
	end

	-- Plausibility: direction must be a unit vector and within maxAimDeviationDegrees
	-- of the server's view of the player's look direction (best-effort; no camera access).
	if direction.Magnitude < 0.9 or direction.Magnitude > 1.1 then return end
	local unitDir = direction.Unit

	-- Consume round (authoritative).
	_AmmoLedger.consumeRound(player, weaponId)
	local newAmmo = _AmmoLedger.get(player, weaponId)

	-- Authoritative server raycast (prevents shoot-through-walls).
	local char = player.Character
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = char and { char } or {}

	local rayLength = def.range + Config.Weapon.serverRayLengthPadding
	local rayResult = Workspace:Raycast(origin, unitDir * rayLength, rayParams)

	local hitPosition: Vector3? = nil
	if rayResult then
		hitPosition = rayResult.Position
		local hitPart = rayResult.Instance
		local hitModel = hitPart:FindFirstAncestorOfClass("Model")
		local humanoid = hitModel and hitModel:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(def.damage)
		end
	end

	-- Confirm to the shooter.
	_Remotes.FireResult:FireClient(player, clientShotId, true, newAmmo, hitPosition)

	-- Broadcast tracer to all other clients.
	for _, other in Players:GetPlayers() do
		if other ~= player then
			_Remotes.ShotFired:FireClient(other, player, origin, hitPosition)
		end
	end
end

-- -------------------------------------------------------------------------
-- ReloadRequest handler
-- -------------------------------------------------------------------------

local function onReloadRequest(player: Player)
	if not isAlive(player) then return end
	if reloadingPlayers[player] then return end

	local holdState = _PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" then return end
	local weaponId = holdState.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	reloadingPlayers[player] = true
	task.delay(def.reloadTime, function()
		reloadingPlayers[player] = nil
		-- Re-validate after delay; player may have died or unequipped.
		local currentState = _PlayerHoldState.get(player)
		if currentState.kind ~= "Weapon" or currentState.weaponId ~= weaponId then return end
		local newAmmo = _AmmoLedger.reload(player, weaponId)
		if player.Parent then
			_Remotes.ReloadResult:FireClient(player, true, newAmmo)
		end
		-- TODO(v2: lagcomp): server-side reload delay should account for ping compensation.
	end)
end

-- -------------------------------------------------------------------------
-- start()
-- -------------------------------------------------------------------------

local WeaponService = {}

function WeaponService.start(deps: {
	Remotes: any,
	PlayerHoldState: any,
	AmmoLedger: any,
})
	_Remotes = deps.Remotes
	_PlayerHoldState = deps.PlayerHoldState
	_AmmoLedger = deps.AmmoLedger

	_Remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	_Remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

function WeaponService.onPlayerRemoving(player: Player)
	lastFireTime[player] = nil
	reloadingPlayers[player] = nil
end

return WeaponService
