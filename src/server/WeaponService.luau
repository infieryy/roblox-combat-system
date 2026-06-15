--!strict
-- Module: server/WeaponService
-- Handles FireRequest / ReloadRequest. Hitscan, fully server-authoritative:
-- the client sends only (origin, direction, clientShotId) — never damage or a
-- victim. The server re-validates ammo, fire-rate, plausibility, and does its
-- OWN raycast from a trusted origin (enforcing line-of-sight / no wall hacks).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

local WeaponService = {}

local ctx: Context = nil :: any
local lastFireAt: { [Player]: number } = {}
local lastFireRequestAt: { [Player]: number } = {}
local lastReloadAt: { [Player]: number } = {}
local reloading: { [Player]: boolean } = {}

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

local function findHumanoidFromHit(hitInstance: Instance): (Humanoid?, Model?)
	local node: Instance? = hitInstance
	while node and node ~= Workspace do
		if node:IsA("Model") then
			local humanoid = node:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return humanoid, node
			end
		end
		node = node.Parent
	end
	return nil, nil
end

local function onFire(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	-- §14.2 rate limit on the request itself.
	local now = os.clock()
	local lastReq = lastFireRequestAt[player]
	if lastReq and (now - lastReq) * 1000 < Config.Security.fireRequestCooldownMs then
		return
	end
	lastFireRequestAt[player] = now

	-- Type-guard the payload (§14.8).
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		return
	end
	local shotId = clientShotId :: number
	local clientOrigin = origin :: Vector3
	local clientDir = direction :: Vector3
	if clientDir.Magnitude < 1e-4 then
		return
	end
	local dir = clientDir.Unit

	-- Must be holding a weapon with a known def.
	local hold = ctx.holdState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		return
	end
	local weaponId = hold.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end

	-- Per-weapon fire rate (server timestamps).
	local lastShot = lastFireAt[player]
	local minInterval = 1 / math.max(def.fireRateRps, 0.01)
	if lastShot and (now - lastShot) < minInterval then
		return
	end

	-- Ammo (mutated only here, via the ledger).
	if not ctx.ammo.canFire(player, weaponId) then
		ctx.remotes.FireResult:FireClient(player, shotId, false, ctx.ammo.get(player, weaponId))
		return
	end

	-- Plausibility: trusted head + look vector.
	local head = getHead(player)
	if not head then
		return
	end
	local lookVector = head.CFrame.LookVector
	if (clientOrigin - head.Position).Magnitude > Config.Weapon.maxOriginDeviation then
		return
	end
	local angle = math.deg(math.acos(math.clamp(dir:Dot(lookVector), -1, 1)))
	if angle > Config.Weapon.maxAimDeviationDegrees then
		return
	end

	-- Commit the round only once plausibility passes.
	if not ctx.ammo.consumeRound(player, weaponId) then
		ctx.remotes.FireResult:FireClient(player, shotId, false, ctx.ammo.get(player, weaponId))
		return
	end
	lastFireAt[player] = now

	-- Authoritative raycast from the trusted head origin (LoS / walls / range).
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	if player.Character then
		rayParams.FilterDescendantsInstances = { player.Character }
	end

	local rayOrigin = head.Position
	local rayLength = def.range + Config.Weapon.serverRayLengthPadding
	local result = Workspace:Raycast(rayOrigin, dir * rayLength, rayParams)

	local hitPosition = rayOrigin + dir * def.range
	if result then
		hitPosition = result.Position
		local humanoid = findHumanoidFromHit(result.Instance)
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(def.damage)
		end
	end

	local newAmmo = ctx.ammo.get(player, weaponId)
	ctx.remotes.FireResult:FireClient(player, shotId, true, newAmmo, hitPosition)

	-- Broadcast to everyone else for tracers / impact FX.
	for _, other in Players:GetPlayers() do
		if other ~= player then
			ctx.remotes.ShotFired:FireClient(other, player, rayOrigin, hitPosition)
		end
	end
end

local function onReload(player: Player)
	local now = os.clock()
	local last = lastReloadAt[player]
	if last and (now - last) * 1000 < Config.Security.reloadRequestCooldownMs then
		return
	end
	lastReloadAt[player] = now

	if reloading[player] then
		return
	end

	local hold = ctx.holdState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		return
	end
	local weaponId = hold.weaponId :: string
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		return
	end

	reloading[player] = true
	task.delay(def.reloadTime, function()
		reloading[player] = nil
		-- Still holding the same weapon when the reload completes?
		local current = ctx.holdState.get(player)
		if current.kind ~= "Weapon" or current.weaponId ~= weaponId then
			return
		end
		local ammo = ctx.ammo.reload(player, weaponId)
		if player.Parent then
			ctx.remotes.ReloadResult:FireClient(player, true, ammo)
		end
	end)
	-- TODO(v2: lagcomp) — rewind targets to the shooter's render time on fire.
end

function WeaponService.clearPlayer(player: Player)
	lastFireAt[player] = nil
	lastFireRequestAt[player] = nil
	lastReloadAt[player] = nil
	reloading[player] = nil
end

function WeaponService.start(context: Context)
	ctx = context
	ctx.remotes.FireRequest.OnServerEvent:Connect(onFire)
	ctx.remotes.ReloadRequest.OnServerEvent:Connect(onReload)
	Players.PlayerRemoving:Connect(function(player)
		WeaponService.clearPlayer(player)
	end)
end

return WeaponService
