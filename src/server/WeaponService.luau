--!strict
-- Module: WeaponService
-- Server-authoritative hitscan weapon handling.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local Remotes = require(script.Parent.Remotes)
local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

local WeaponService = {}

local remotes: Remotes.RemotesTable? = nil
local lastFireAt: { [Player]: number } = {}
local lastWeaponFireAt: { [Player]: { [string]: number } } = {}
local lastReloadAt: { [Player]: number } = {}
local reloadTokens: { [Player]: number } = {}

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
	local dot = math.clamp(a:Dot(b), -1, 1)
	return math.deg(math.acos(dot))
end

local function buildRaycastFilter(shooter: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	local character = shooter.Character
	if character then
		table.insert(filter, character)
	end
	local hold = PlayerHoldState.get(shooter)
	if hold.instance then
		table.insert(filter, hold.instance)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	return params
end

local function getTrustedOrigin(player: Player): Vector3?
	local head = getHead(player)
	if head then
		return head.Position
	end
	return nil
end

local function getTrustedLook(player: Player): Vector3?
	local head = getHead(player)
	if head then
		return head.CFrame.LookVector
	end
	return nil
end

local function applyDamage(hitInstance: Instance, damage: number, shooter: Player)
	local model = hitInstance:FindFirstAncestorOfClass("Model")
	if not model then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		local creator = Instance.new("ObjectValue")
		creator.Name = "creator"
		creator.Value = shooter
		creator.Parent = humanoid
		game:GetService("Debris"):AddItem(creator, 2)
		humanoid:TakeDamage(damage)
	end
end

local function onFireRequest(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	if not remotes then
		return
	end

	local shotId = if typeof(clientShotId) == "number" then clientShotId else 0

	local now = os.clock()
	local last = lastFireAt[player] or 0
	if (now - last) * 1000 < Config.Security.fireRequestCooldownMs then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end
	lastFireAt[player] = now

	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	local dir = (direction :: Vector3)
	if dir.Magnitude < 0.001 then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end
	dir = dir.Unit

	if not isAlive(player) then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	local weaponId = hold.weaponId
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	local weaponFireTimes = lastWeaponFireAt[player]
	if not weaponFireTimes then
		weaponFireTimes = {}
		lastWeaponFireAt[player] = weaponFireTimes
	end
	local minInterval = 1 / def.fireRateRps
	local lastWeaponFire = weaponFireTimes[weaponId] or 0
	if now - lastWeaponFire < minInterval then
		remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.canFire(player, weaponId) then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	local trustedOrigin = getTrustedOrigin(player)
	local trustedLook = getTrustedLook(player)
	if not trustedOrigin or not trustedLook then
		remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if (origin :: Vector3 - trustedOrigin).Magnitude > 4 then
		remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if angleBetween(dir, trustedLook) > Config.Weapon.maxAimDeviationDegrees then
		remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.consumeRound(player, weaponId) then
		remotes.FireResult:FireClient(player, shotId, false, 0, nil)
		return
	end

	weaponFireTimes[weaponId] = now

	-- TODO(v2: lagcomp): rewind player positions to client shot timestamp before raycast.
	local rayOrigin = trustedOrigin
	local rayLength = def.range + Config.Weapon.serverRayLengthPadding
	local params = buildRaycastFilter(player)
	local result = Workspace:Raycast(rayOrigin, dir * rayLength, params)

	local hitPosition = rayOrigin + dir * rayLength
	if result then
		hitPosition = result.Position
		applyDamage(result.Instance, def.damage, player)
	end

	local newAmmo = AmmoLedger.get(player, weaponId)
	remotes.FireResult:FireClient(player, shotId, true, newAmmo, hitPosition)
	remotes.ShotFired:FireAllClients(player, rayOrigin, hitPosition)
end

local function onReloadRequest(player: Player)
	if not remotes then
		return
	end

	local now = os.clock()
	local last = lastReloadAt[player] or 0
	if (now - last) * 1000 < Config.Security.reloadRequestCooldownMs then
		remotes.ReloadResult:FireClient(player, false, 0)
		return
	end
	lastReloadAt[player] = now

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

	local token = (reloadTokens[player] or 0) + 1
	reloadTokens[player] = token

	task.delay(def.reloadTime, function()
		if reloadTokens[player] ~= token then
			return
		end
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

function WeaponService.onPlayerRemoving(player: Player)
	lastFireAt[player] = nil
	lastWeaponFireAt[player] = nil
	lastReloadAt[player] = nil
	reloadTokens[player] = nil
end

function WeaponService.start(remoteTable: Remotes.RemotesTable)
	remotes = remoteTable
	remoteTable.FireRequest.OnServerEvent:Connect(onFireRequest)
	remoteTable.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

return WeaponService
