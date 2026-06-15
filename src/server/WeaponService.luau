--!strict
-- Module: WeaponService
-- Authoritative hitscan shooting and reload.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ItemRegistry = require(game:GetService("ReplicatedStorage").Shared.ItemRegistry)

local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type Remotes = typeof(require(script.Parent.Remotes).build())

local WeaponService = {}

local remotes: Remotes? = nil
local lastFireAt: { [Player]: number } = {}
local lastFireRequestAt: { [Player]: number } = {}
local lastReloadRequestAt: { [Player]: number } = {}
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

local function fireRateLimited(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastFireRequestAt[player] or 0
	if now - last < Config.Security.fireRequestCooldownMs then
		return true
	end
	lastFireRequestAt[player] = now
	return false
end

local function reloadRateLimited(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastReloadRequestAt[player] or 0
	if now - last < Config.Security.reloadRequestCooldownMs then
		return true
	end
	lastReloadRequestAt[player] = now
	return false
end

local function angleBetween(a: Vector3, b: Vector3): number
	if a.Magnitude < 1e-4 or b.Magnitude < 1e-4 then
		return 180
	end
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
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
	local victimCharacter = model
	local shooterCharacter = shooter.Character
	if victimCharacter == shooterCharacter then
		return
	end
	humanoid:TakeDamage(damage)
end

local function authoritativeRaycast(origin: Vector3, direction: Vector3, range: number, shooter: Player): (Vector3?, Instance?)
	local unitDirection = direction.Magnitude > 0 and direction.Unit or Vector3.new(0, 0, -1)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if shooter.Character then
		table.insert(filter, shooter.Character)
	end
	local hold = PlayerHoldState.get(shooter)
	if hold.instance then
		table.insert(filter, hold.instance)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, unitDirection * (range + Config.Weapon.serverRayLengthPadding), params)
	if result then
		return result.Position, result.Instance
	end
	return origin + unitDirection * range, nil
end

local function onFire(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	if fireRateLimited(player) then
		return
	end
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		return
	end
	if not isAlive(player) then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, 0, nil)
		end
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
	local lastShot = lastFireAt[player] or 0
	if now - lastShot < minInterval then
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

	local head = getHead(player)
	if not head then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	local trustedOrigin = head.Position
	if (origin - trustedOrigin).Magnitude > Config.Security.maxOriginDistanceFromHead then
		if remotes then
			remotes.FireResult:FireClient(player, clientShotId, false, AmmoLedger.get(player, weaponId), nil)
		end
		return
	end

	local lookVector = head.CFrame.LookVector
	if angleBetween(direction, lookVector) > Config.Weapon.maxAimDeviationDegrees then
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

	lastFireAt[player] = now

	-- TODO(v2: lagcomp): rewind player positions for hit validation.
	local hitPosition, hitInstance = authoritativeRaycast(trustedOrigin, direction, def.range, player)
	if hitInstance then
		applyDamage(hitInstance, def.damage, player)
	end

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.FireResult:FireClient(player, clientShotId, true, ammo, hitPosition)
		for _, otherPlayer in Players:GetPlayers() do
			if otherPlayer ~= player then
				remotes.ShotFired:FireClient(otherPlayer, player, trustedOrigin, hitPosition or trustedOrigin + direction.Unit * def.range)
			end
		end
	end
end

local function onReload(player: Player)
	if reloadRateLimited(player) then
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

	local now = os.clock()
	if (reloadingUntil[player] or 0) > now then
		if remotes then
			remotes.ReloadResult:FireClient(player, false, AmmoLedger.get(player, weaponId))
		end
		return
	end

	reloadingUntil[player] = now + def.reloadTime
	task.delay(def.reloadTime, function()
		if not player.Parent then
			return
		end
		local currentHold = PlayerHoldState.get(player)
		if currentHold.kind ~= "Weapon" or currentHold.weaponId ~= weaponId then
			return
		end
		local ammo = AmmoLedger.reload(player, weaponId)
		if remotes then
			remotes.ReloadResult:FireClient(player, true, ammo)
		end
	end)
end

function WeaponService.start(remoteTable: Remotes)
	remotes = remoteTable
	remoteTable.FireRequest.OnServerEvent:Connect(onFire)
	remoteTable.ReloadRequest.OnServerEvent:Connect(onReload)
end

function WeaponService.onPlayerRemoving(player: Player)
	lastFireAt[player] = nil
	lastFireRequestAt[player] = nil
	lastReloadRequestAt[player] = nil
	reloadingUntil[player] = nil
end

return WeaponService
