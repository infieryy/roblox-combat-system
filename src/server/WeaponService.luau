--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local PlayerHoldState = require(script.Parent:WaitForChild("PlayerHoldState"))
local AmmoLedger = require(script.Parent:WaitForChild("AmmoLedger"))

local WeaponService = {}

local remotes: any = nil
local lastShotAt: { [Player]: number } = {}

local function withinAimDeviation(player: Player, origin: Vector3, direction: Vector3): boolean
	local character = player.Character
	if not character then
		return false
	end
	local head = character:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return false
	end

	local look = head.CFrame.LookVector
	local dir = direction.Unit
	local dot = math.clamp(look:Dot(dir), -1, 1)
	local angle = math.deg(math.acos(dot))
	return angle <= Config.Validation.maxAimDeviationDegrees
end

local function fireRay(player: Player, weaponDef: any, origin: Vector3, direction: Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	local result = workspace:Raycast(
		origin,
		direction.Unit * (weaponDef.range + Config.Weapon.serverRayLengthPadding),
		params
	)
	if not result then
		return nil
	end

	local model = result.Instance:FindFirstAncestorOfClass("Model")
	local humanoid = model and model:FindFirstChildOfClass("Humanoid") or nil
	if humanoid then
		humanoid:TakeDamage(weaponDef.damage)
	end
	return result.Position
end

local function onFireRequest(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		remotes.FireResult:FireClient(player, false, "not_holding_weapon", payload.clientShotId, nil)
		return
	end

	local weaponDef = ItemRegistry.getWeaponDef(hold.weaponId)
	if not weaponDef then
		remotes.FireResult:FireClient(player, false, "unknown_weapon", payload.clientShotId, nil)
		return
	end

	local origin = payload.origin
	local direction = payload.direction
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude <= 0 then
		remotes.FireResult:FireClient(player, false, "bad_payload", payload.clientShotId, nil)
		return
	end

	if not withinAimDeviation(player, origin, direction) then
		remotes.FireResult:FireClient(player, false, "aim_deviation", payload.clientShotId, AmmoLedger.getAmmo(player, hold.weaponId))
		return
	end

	local now = os.clock()
	local minDelay = 1 / weaponDef.fireRate
	local last = lastShotAt[player] or 0
	if now - last < minDelay then
		remotes.FireResult:FireClient(player, false, "rate_limited", payload.clientShotId, AmmoLedger.getAmmo(player, hold.weaponId))
		return
	end
	lastShotAt[player] = now

	local consumed, ammo = AmmoLedger.consumeRound(player, hold.weaponId)
	if not consumed then
		remotes.FireResult:FireClient(player, false, "no_ammo", payload.clientShotId, ammo)
		return
	end

	local hitPosition = fireRay(player, weaponDef, origin, direction)
	remotes.FireResult:FireClient(player, true, "ok", payload.clientShotId, ammo, hitPosition)
end

local function onReloadRequest(player: Player)
	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.weaponId then
		return
	end

	local weaponDef = ItemRegistry.getWeaponDef(hold.weaponId)
	if not weaponDef then
		return
	end

	local ammo = AmmoLedger.reload(player, hold.weaponId)
	remotes.EquipResult:FireClient(player, true, hold.weaponId, ammo, "reloaded")
end

function WeaponService.start(remoteMap: any)
	remotes = remoteMap
	remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)

	Players.PlayerRemoving:Connect(function(player)
		lastShotAt[player] = nil
	end)
end

return WeaponService
