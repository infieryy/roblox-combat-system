--!strict
-- Module: Authoritative hitscan firing and reload validation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger = require(script.Parent.AmmoLedger)
type RemotesModule = typeof(require(script.Parent.Remotes))
type RemoteBundle = RemotesModule.RemoteBundle

type EquipServiceContract = {
	getEquipped: (player: Player) -> (Instance?, string?),
}

local WeaponService = {}

local remotes: RemoteBundle? = nil

local lastFireRequestAt: { [Player]: number } = {}
local lastShotAt: { [Player]: number } = {}
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
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isFireRateLimited(player: Player): boolean
	local now = os.clock()
	local previous = lastFireRequestAt[player]
	lastFireRequestAt[player] = now
	if not previous then
		return false
	end
	return (now - previous) * 1000 < Config.Security.fireRequestCooldownMs
end

local function canShootByWeaponCadence(player: Player, fireRateRps: number): boolean
	local now = os.clock()
	local requiredGap = if fireRateRps > 0 then (1 / fireRateRps) else 0
	local previous = lastShotAt[player]
	if previous and now - previous < requiredGap then
		return false
	end
	lastShotAt[player] = now
	return true
end

local function getHeldWeapon(player: Player): (Instance?, string?)
	local state = PlayerHoldState.get(player)
	if state.kind ~= "Weapon" or not state.instance or not state.weaponId then
		return nil, nil
	end
	return state.instance, state.weaponId
end

local function sendFireResult(player: Player, shotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
	if remotes then
		remotes.FireResult:FireClient(player, shotId, ok, ammo, hitPosition)
	end
end

local function sendReloadResult(player: Player, ok: boolean, ammo: number)
	if remotes then
		remotes.ReloadResult:FireClient(player, ok, ammo)
	end
end

local function onFireRequest(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	if isFireRateLimited(player) then
		return
	end

	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		return
	end

	local shotId = math.floor(clientShotId :: number)
	if shotId < 0 then
		return
	end

	local weapon, weaponId = getHeldWeapon(player)
	if not weapon or not weaponId then
		sendFireResult(player, shotId, false, 0, nil)
		return
	end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		sendFireResult(player, shotId, false, 0, nil)
		return
	end

	if not canShootByWeaponCadence(player, def.fireRateRps) then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.canFire(player, weaponId) then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local head = getHead(player)
	if not head then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local suppliedOrigin = origin :: Vector3
	local suppliedDirection = direction :: Vector3
	if suppliedDirection.Magnitude <= 0 then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local normalizedDirection = suppliedDirection.Unit
	local lookDot = math.clamp(normalizedDirection:Dot(head.CFrame.LookVector), -1, 1)
	local deviationDegrees = math.deg(math.acos(lookDot))
	if deviationDegrees > Config.Weapon.maxAimDeviationDegrees then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	local trustedOrigin = head.Position + head.CFrame.LookVector * 0.5
	if (suppliedOrigin - trustedOrigin).Magnitude > Config.Weapon.serverRayLengthPadding then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end

	if not AmmoLedger.consumeRound(player, weaponId) then
		sendFireResult(player, shotId, false, AmmoLedger.get(player, weaponId), nil)
		return
	end
	local ammoNow = AmmoLedger.get(player, weaponId)

	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.IgnoreWater = true
	castParams.FilterDescendantsInstances = if player.Character then { player.Character } else {}

	local rayDirection = normalizedDirection * def.range
	local result = Workspace:Raycast(trustedOrigin, rayDirection, castParams)
	local hitPosition = trustedOrigin + rayDirection
	if result then
		hitPosition = result.Position
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		local hitHumanoid = if hitModel then hitModel:FindFirstChildOfClass("Humanoid") else nil
		if hitHumanoid and hitModel ~= player.Character then
			hitHumanoid:TakeDamage(def.damage)
		end
	end

	sendFireResult(player, shotId, true, ammoNow, hitPosition)
	if remotes then
		remotes.ShotFired:FireAllClients(player, trustedOrigin, hitPosition)
	end
end

local function onReloadRequest(player: Player)
	local weapon, weaponId = getHeldWeapon(player)
	if not weapon or not weaponId then
		sendReloadResult(player, false, 0)
		return
	end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		sendReloadResult(player, false, 0)
		return
	end

	local token = (reloadTokens[player] or 0) + 1
	reloadTokens[player] = token

	task.delay(def.reloadTime, function()
		if reloadTokens[player] ~= token then
			return
		end
		local latestWeapon, latestWeaponId = getHeldWeapon(player)
		if latestWeapon ~= weapon or latestWeaponId ~= weaponId then
			sendReloadResult(player, false, AmmoLedger.get(player, weaponId))
			return
		end
		local ammo = AmmoLedger.reload(player, weaponId)
		sendReloadResult(player, true, ammo)
	end)
end

function WeaponService.start(remoteBundle: RemoteBundle, _equip: EquipServiceContract)
	remotes = remoteBundle
	remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

function WeaponService.cleanupPlayer(player: Player)
	lastFireRequestAt[player] = nil
	lastShotAt[player] = nil
	reloadTokens[player] = nil
end

return WeaponService
