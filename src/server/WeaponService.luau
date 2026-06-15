--!strict
-- Module: WeaponService
-- Server-authoritative hitscan shooting and reload.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.Shared.Config)
local ItemRegistry = require(game.ReplicatedStorage.Shared.ItemRegistry)

local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type RemotesTable = typeof(require(script.Parent.Remotes).build())

local WeaponService = {}

local remotes: RemotesTable? = nil
local lastFireRequest: { [Player]: number } = {}
local lastReloadRequest: { [Player]: number } = {}
local lastShotTime: { [Player]: number } = {}
local reloadingUntil: { [Player]: number } = {}

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

local function isAlive(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function fireRateLimitOk(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastFireRequest[player] or 0
	if now - last < Config.Security.fireRequestCooldownMs then
		return false
	end
	lastFireRequest[player] = now
	return true
end

local function reloadRateLimitOk(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastReloadRequest[player] or 0
	if now - last < Config.Security.reloadRequestCooldownMs then
		return false
	end
	lastReloadRequest[player] = now
	return true
end

local function buildRaycastParams(shooterCharacter: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { shooterCharacter }
	return params
end

local function angleBetween(a: Vector3, b: Vector3): number
	local denom = a.Magnitude * b.Magnitude
	if denom < 1e-6 then
		return 180
	end
	return math.deg(math.acos(math.clamp(a:Dot(b) / denom, -1, 1)))
end

local function authoritativeRaycast(
	origin: Vector3,
	direction: Vector3,
	range: number,
	params: RaycastParams
): RaycastResult?
	local unit = direction.Magnitude > 0 and direction.Unit or Vector3.new(0, 0, -1)
	return Workspace:Raycast(origin, unit * range, params)
end

local function applyDamage(result: RaycastResult, damage: number, shooter: Player)
	local hit = result.Instance
	local model = hit:FindFirstAncestorOfClass("Model")
	if not model then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local victimPlayer = Players:GetPlayerFromCharacter(model)
	if victimPlayer == shooter then
		return
	end
	humanoid:TakeDamage(damage)
end

local function onFireRequest(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	if not fireRateLimitOk(player) then
		return
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		return
	end
	if not isAlive(player) then
		return
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		end
		return
	end

	local weaponId = hold.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		end
		return
	end

	local now = os.clock()
	local minInterval = 1 / def.fireRateRps
	if now - (lastShotTime[player] or 0) < minInterval then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	if reloadingUntil[player] and now < reloadingUntil[player] then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	if not AmmoLedger.canFire(player, weaponId) then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		end
		return
	end

	local character = player.Character
	local head = getHead(player)
	if not character or not head then
		return
	end

	local trustedOrigin = head.Position
	if (origin - trustedOrigin).Magnitude > 4 then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	local look = head.CFrame.LookVector
	if angleBetween(direction, look) > Config.Weapon.maxAimDeviationDegrees then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	if not AmmoLedger.consumeRound(player, weaponId) then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		end
		return
	end

	lastShotTime[player] = now

	local rayDirection = direction
	if def.spread > 0 then
		local spreadRad = math.rad(def.spread)
		rayDirection = (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(
			(math.random() - 0.5) * spreadRad,
			(math.random() - 0.5) * spreadRad,
			0
		)).LookVector
	end

	local range = def.range + Config.Weapon.serverRayLengthPadding
	local params = buildRaycastParams(character)
	local result = authoritativeRaycast(trustedOrigin, rayDirection, range, params)

	local hitPosition: Vector3? = nil
	if result then
		hitPosition = result.Position
		applyDamage(result, def.damage, player)
	else
		hitPosition = trustedOrigin + rayDirection.Unit * range
	end

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.FireResult:FireClient(player, clientShotId, true, ammo, hitPosition)
		remotes.ShotFired:FireAllClients(player, trustedOrigin, hitPosition :: Vector3)
	end

	-- TODO(v2: lagcomp) server-side rewind for hit validation
end

local function onReloadRequest(player: Player)
	if not reloadRateLimitOk(player) then
		return
	end
	if not isAlive(player) then
		return
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		if remotes then
			remotes.ReloadResult:FireClient(player, false, 0)
		end
		return
	end

	local weaponId = hold.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		if remotes then
			remotes.ReloadResult:FireClient(player, false, 0)
		end
		return
	end

	reloadingUntil[player] = os.clock() + def.reloadTime
	task.delay(def.reloadTime, function()
		if not player.Parent then
			return
		end
		local current = PlayerHoldState.get(player)
		if current.kind ~= "Weapon" or current.weaponId ~= weaponId then
			return
		end
		local ammo = AmmoLedger.reload(player, weaponId)
		if remotes then
			remotes.ReloadResult:FireClient(player, true, ammo)
		end
	end)
end

function WeaponService.init(remotesTable: RemotesTable)
	remotes = remotesTable
	remotesTable.FireRequest.OnServerEvent:Connect(onFireRequest)
	remotesTable.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

function WeaponService.onPlayerRemoving(player: Player)
	lastFireRequest[player] = nil
	lastReloadRequest[player] = nil
	lastShotTime[player] = nil
	reloadingUntil[player] = nil
end

return WeaponService
