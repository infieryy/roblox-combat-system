--!strict
-- Module: WeaponService
-- Authoritative hitscan fire and reload handling.
-- Listens for FireRequest (C→S) and ReloadRequest (C→S).
--
-- Anti-cheat pipeline for each shot (§15):
--   1. Rate-limit: enforce minimum interval per weapon fire rate.
--   2. Hold check: player must be holding the exact weapon via PlayerHoldState.
--   3. Fire rate: server timestamp >= 1/fireRateRps since last shot.
--   4. Ammo: AmmoLedger.canFire → consumeRound (or reject).
--   5. Plausibility: direction within maxAimDeviationDegrees of server-seen look vector.
--   6. Origin plausibility: submitted origin near character head.
--   7. Authoritative server raycast (enforces LoS, walls, range).
--   8. Damage humanoid on confirmed hit.
--   9. Broadcast ShotFired to all clients for tracer/impact effects.
--
-- TODO(v2: lagcomp) — rewind-based lag compensation not implemented in v1.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local WeaponService = {}

-- Injected dependencies
local Remotes: any         = nil
local PlayerHoldState: any = nil
local AmmoLedger: any      = nil

-- -------------------------------------------------------------------------
-- Per-player fire rate tracking
-- -------------------------------------------------------------------------

local lastFireTime: { [Player]: number }     = {}
local lastFireReqTime: { [Player]: number }  = {}

-- -------------------------------------------------------------------------
-- Rate limiting (network-level, separate from weapon fire rate)
-- -------------------------------------------------------------------------

local function checkFireCooldown(player: Player): boolean
	local nowMs = os.clock() * 1000
	local last  = lastFireReqTime[player] or 0
	if nowMs - last < Config.Security.fireRequestCooldownMs then
		return false
	end
	lastFireReqTime[player] = nowMs
	return true
end

-- -------------------------------------------------------------------------
-- Utility
-- -------------------------------------------------------------------------

local function getHeadCFrame(player: Player): CFrame?
	local character = player.Character
	if not character then return nil end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.CFrame
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then
		return (root :: BasePart).CFrame
	end
	return nil
end

-- -------------------------------------------------------------------------
-- FireRequest handler
-- -------------------------------------------------------------------------

local function onFireRequest(player: Player, origin: unknown, direction: unknown, clientShotId: unknown)
	-- Network rate limit
	if not checkFireCooldown(player) then return end

	-- Type validation
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or typeof(clientShotId) ~= "number" then
		return
	end
	local originV    = origin :: Vector3
	local directionV = direction :: Vector3
	local shotId     = clientShotId :: number

	-- Normalise direction (don't trust client magnitude)
	if directionV.Magnitude < 0.001 then return end
	directionV = directionV.Unit

	-- Hold state check: must be holding a weapon
	local holdState = PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" then return end

	local weapon   = holdState.instance
	local weaponId = holdState.weaponId
	if not weapon or not weaponId then return end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	-- Weapon fire rate check (server-authoritative timestamp)
	local now         = os.clock()
	local minInterval = 1 / def.fireRateRps
	local lastTime    = lastFireTime[player]
	if lastTime and (now - lastTime) < minInterval then
		Remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId))
		return
	end

	-- Ammo check
	if not AmmoLedger.canFire(player, weaponId) then
		Remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end

	-- Plausibility: origin must be near the character's head
	local headCFrame = getHeadCFrame(player)
	if not headCFrame then return end
	local headPos = headCFrame.Position
	if (originV - headPos).Magnitude > Config.Weapon.maxOriginDistance then
		warn(("[WeaponService] %s: origin too far from head (%.1f studs)"):format(player.Name, (originV - headPos).Magnitude))
		Remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId))
		return
	end

	-- Plausibility: direction must be within tolerance of server-side look vector
	local serverLook  = headCFrame.LookVector
	local angleDeg    = math.deg(math.acos(math.clamp(serverLook:Dot(directionV), -1, 1)))
	if angleDeg > Config.Weapon.maxAimDeviationDegrees then
		warn(("[WeaponService] %s: aim plausibility failed (%.1f°)"):format(player.Name, angleDeg))
		Remotes.FireResult:FireClient(player, shotId, false, AmmoLedger.get(player, weaponId))
		return
	end

	-- Consume ammo (after all checks pass so exploiters can't drain ammo with bad shots)
	if not AmmoLedger.consumeRound(player, weaponId) then
		Remotes.FireResult:FireClient(player, shotId, false, 0)
		return
	end
	lastFireTime[player] = now
	local newAmmo = AmmoLedger.get(player, weaponId)

	-- Authoritative server raycast from a trusted origin along the submitted direction.
	-- Ray starts from the server's view of the head position (not the client's submitted origin)
	-- to prevent shoot-through-walls exploits where the client submits an origin inside a wall.
	local trustedOrigin = headPos + headCFrame.UpVector * 1.5  -- approximate eye level

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	-- Exclude the shooter's character from the ray.
	local exclusions: { Instance } = {}
	if player.Character then
		table.insert(exclusions, player.Character)
	end
	raycastParams.FilterDescendantsInstances = exclusions

	local rayLength = def.range + Config.Weapon.serverRayLengthPadding
	local result    = Workspace:Raycast(trustedOrigin, directionV * rayLength, raycastParams)

	local hitPosition: Vector3? = nil
	if result then
		hitPosition = result.Position
		-- Check for humanoid hit and apply damage.
		local hitInstance = result.Instance
		if hitInstance then
			-- Walk up to find the character humanoid.
			local humanoid: Humanoid? = nil
			local parent = hitInstance.Parent
			if parent then
				humanoid = parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
				if not humanoid and parent.Parent then
					humanoid = parent.Parent:FindFirstChildOfClass("Humanoid") :: Humanoid?
				end
			end
			if humanoid and humanoid.Health > 0 then
				-- Verify the hit target isn't the shooter (paranoia check).
				local victimPlayer = Players:GetPlayerFromCharacter(humanoid.Parent)
				if victimPlayer ~= player then
					humanoid:TakeDamage(def.damage)
				end
			end
		end
	end

	-- Confirm to the shooter.
	Remotes.FireResult:FireClient(player, shotId, true, newAmmo, hitPosition)

	-- Broadcast to all other clients for tracer / impact effects.
	local finalHit = hitPosition or (trustedOrigin + directionV * def.range)
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			Remotes.ShotFired:FireClient(otherPlayer, player, trustedOrigin, finalHit)
		end
	end
end

-- -------------------------------------------------------------------------
-- ReloadRequest handler
-- -------------------------------------------------------------------------

local function onReloadRequest(player: Player)
	local holdState = PlayerHoldState.get(player)
	if holdState.kind ~= "Weapon" then return end

	local weaponId = holdState.weaponId
	if not weaponId then return end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	-- Already full?
	if AmmoLedger.get(player, weaponId) >= def.maxAmmo then
		Remotes.ReloadResult:FireClient(player, false, def.maxAmmo)
		return
	end

	-- Wait for the reload animation time before refilling.
	task.delay(def.reloadTime, function()
		-- Re-validate: player must still be holding the same weapon.
		local currentState = PlayerHoldState.get(player)
		if currentState.kind ~= "Weapon" or currentState.weaponId ~= weaponId then
			return
		end
		local newAmmo = AmmoLedger.reload(player, weaponId)
		Remotes.ReloadResult:FireClient(player, true, newAmmo)
	end)
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function WeaponService.init(
	remotes: any,
	playerHoldState: any,
	ammoLedger: any
)
	Remotes         = remotes
	PlayerHoldState = playerHoldState
	AmmoLedger      = ammoLedger

	Remotes.FireRequest.OnServerEvent:Connect(onFireRequest)
	Remotes.ReloadRequest.OnServerEvent:Connect(onReloadRequest)
end

-- Cleanup per-player state on disconnect.
function WeaponService.clearPlayer(player: Player)
	lastFireTime[player]    = nil
	lastFireReqTime[player] = nil
end

return WeaponService
