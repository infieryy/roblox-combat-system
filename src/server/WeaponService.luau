--!strict
-- Module: server/WeaponService.luau

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)
local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

local WeaponService = {}

local remotes: {
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ShotFired: RemoteEvent,
	ReloadRequest: RemoteEvent,
	ReloadResult: RemoteEvent,
}? = nil

local lastFireRequestAt: { [Player]: number } = {}
local lastReloadRequestAt: { [Player]: number } = {}
local lastShotAt: { [Player]: number } = {}
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

local function angleBetween(a: Vector3, b: Vector3): number
	local dot = math.clamp(a.Unit:Dot(b.Unit), -1, 1)
	return math.deg(math.acos(dot))
end

local function buildRaycastParams(character: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { character }
	return params
end

local function applyDamage(hitInstance: Instance, damage: number, shooter: Player)
	local model = hitInstance:FindFirstAncestorOfClass("Model")
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

local function authoritativeRaycast(player: Player, origin: Vector3, direction: Vector3, range: number): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local unitDirection = direction.Unit
	local params = buildRaycastParams(character)
	local result = Workspace:Raycast(origin, unitDirection * (range + Config.Weapon.serverRayLengthPadding), params)
	if result then
		return result.Position
	end
	return origin + unitDirection * range
end

function WeaponService.onFire(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	if not remotes then
		return
	end

	local now = os.clock()
	local lastAt = lastFireRequestAt[player] or 0
	if (now - lastAt) * 1000 < Config.Security.fireRequestCooldownMs then
		return
	end
	lastFireRequestAt[player] = now

	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	if not isAlive(player) then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	local weaponId = hold.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	if reloadingUntil[player] and now < reloadingUntil[player] then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local minInterval = 1 / def.fireRateRps
	local lastShot = lastShotAt[player] or 0
	if now - lastShot < minInterval then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.canFire(player, weaponId) then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	local head = getHead(player)
	if not head then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local trustedOrigin = head.Position
	if (origin - trustedOrigin).Magnitude > 6 then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local lookVector = head.CFrame.LookVector
	if angleBetween(direction, lookVector) > Config.Weapon.maxAimDeviationDegrees then
		remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.consumeRound(player, weaponId) then
		remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		return
	end

	lastShotAt[player] = now

	-- TODO(v2: lagcomp): rewind hitboxes here before raycast.

	local spreadDirection = direction.Unit
	if def.spread > 0 then
		local spreadX = (math.random() - 0.5) * def.spread
		local spreadY = (math.random() - 0.5) * def.spread
		spreadDirection = (lookVector + head.CFrame.RightVector * spreadX + head.CFrame.UpVector * spreadY).Unit
	end

	local hitPosition = authoritativeRaycast(player, trustedOrigin, spreadDirection, def.range)
	local params = buildRaycastParams(player.Character :: Model)
	local hitResult = Workspace:Raycast(trustedOrigin, spreadDirection * (def.range + Config.Weapon.serverRayLengthPadding), params)
	if hitResult then
		applyDamage(hitResult.Instance, def.damage, player)
		hitPosition = hitResult.Position
	end

	local ammo = AmmoLedger.get(player, weaponId)
	remotes.FireResult:FireClient(player, clientShotId, true, ammo, hitPosition)
	if hitPosition then
		remotes.ShotFired:FireAllClients(player, trustedOrigin, hitPosition)
	end
end

local function onReloadRequest(player: Player)
	if not remotes then
		return
	end

	local now = os.clock()
	local lastAt = lastReloadRequestAt[player] or 0
	if (now - lastAt) * 1000 < Config.Security.reloadRequestCooldownMs then
		return
	end
	lastReloadRequestAt[player] = now

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		remotes.ReloadResult:FireClient(player, false, 0)
		return
	end

	local weaponId = hold.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		remotes.ReloadResult:FireClient(player, false, 0)
		return
	end

	reloadingUntil[player] = now + def.reloadTime
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

function WeaponService.configure(remoteTable: typeof(remotes))
	remotes = remoteTable
end

function WeaponService.start()
	if not remotes then
		warn("[WeaponService] remotes not configured")
		return
	end

	remotes.FireRequest.OnServerEvent:Connect(function(player, origin, direction, clientShotId)
		WeaponService.onFire(player, origin, direction, clientShotId)
	end)
	remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

function WeaponService.onPlayerRemoving(player: Player)
	lastFireRequestAt[player] = nil
	lastReloadRequestAt[player] = nil
	lastShotAt[player] = nil
	reloadingUntil[player] = nil
end

return WeaponService
