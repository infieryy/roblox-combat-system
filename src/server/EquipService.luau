--!strict
-- Module: EquipService
-- Handles E-to-equip weapon requests. Blueprint §10.6.
-- Pipeline:
--   rate-limit → classify==Weapon → weaponId/def valid → distance ≤ maxEquipDistance
--   → not equipped by another → PlayerHoldState.setWeapon (prev Prop → DragService.forceRelease)
--   → AmmoLedger.onEquip → attach weapon to character → EquipResult(true)
-- Exposes forceUnequip() for DragService cross-service teardown.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config         = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ItemRegistry   = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))
local GeometryUtil   = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))

local _Remotes: any = nil
local _PlayerHoldState: any = nil
local _AmmoLedger: any = nil
local _forceReleaseCallback: ((Player) -> ())? = nil

local lastEquipRequest: { [Player]: number } = {}

-- Track which weapon Instance each player has equipped (for unequip teardown).
local equippedWeapons: { [Player]: { weapon: Instance, weaponId: string } } = {}

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
-- Teardown
-- -------------------------------------------------------------------------

-- forceUnequip is called by DragService when the player grabs a prop while
-- holding a weapon.
local function _unequip(player: Player, notifyClient: boolean)
	local entry = equippedWeapons[player]
	if not entry then return end
	equippedWeapons[player] = nil

	-- Return weapon to Workspace and clear its held-by stamp.
	-- In v1 the weapon simply drops back into the world at its current position.
	-- A v2 inventory system would handle persistent storage.
	if entry.weapon and entry.weapon.Parent then
		entry.weapon:SetAttribute(Config.Detection.heldByAttribute, nil)
		entry.weapon.Parent = Workspace
	end

	_PlayerHoldState.clear(player)

	if notifyClient and player.Parent then
		_Remotes.EquipResult:FireClient(player, false, nil, nil)
	end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

local EquipService = {}

function EquipService.forceUnequip(player: Player)
	_unequip(player, true)
end

function EquipService.setForceReleaseCallback(callback: (Player) -> ())
	_forceReleaseCallback = callback
end

-- -------------------------------------------------------------------------
-- EquipRequest handler
-- -------------------------------------------------------------------------

local function onEquipRequest(player: Player, requested: unknown)
	-- Rate limit.
	local now = os.clock()
	if now - (lastEquipRequest[player] or 0) < Config.Security.equipRequestCooldown then return end
	lastEquipRequest[player] = now

	if typeof(requested) ~= "Instance" then return end
	local weapon = requested :: Instance
	if not weapon:IsDescendantOf(Workspace) then return end
	if not isAlive(player) then return end

	-- Classification.
	if ItemRegistry.classify(weapon) ~= "Weapon" then return end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	if not weaponId then return end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then return end

	-- Distance check (use visual centre for Blender-safe measurement).
	local head = getHead(player)
	if not head then return end
	local weaponCentre = GeometryUtil.getVisualCenter(weapon)
	local distance = (weaponCentre - head.Position).Magnitude
	if distance > Config.Security.maxEquipDistance then return end

	-- Already held by someone else (§14.6: treat as cosmetic, server wins).
	local heldBy = weapon:GetAttribute(Config.Detection.heldByAttribute)
	if typeof(heldBy) == "number" and heldBy ~= player.UserId then return end

	-- One-item rule: drop a held prop first.
	local prev = _PlayerHoldState.get(player)
	if prev.kind == "Prop" then
		if _forceReleaseCallback then
			_forceReleaseCallback(player)
		end
	elseif prev.kind == "Weapon" then
		-- Already holding a weapon; replace it.
		_unequip(player, false)
	end

	-- Attach weapon to character (removed from world).
	local char = player.Character
	if not char then return end
	weapon.Parent = char
	weapon:SetAttribute(Config.Detection.heldByAttribute, player.UserId)

	_PlayerHoldState.setWeapon(player, weapon, weaponId)
	_AmmoLedger.onEquip(player, weaponId)

	equippedWeapons[player] = { weapon = weapon, weaponId = weaponId }

	local ammo = _AmmoLedger.get(player, weaponId)
	_Remotes.EquipResult:FireClient(player, true, weaponId, ammo)
end

-- -------------------------------------------------------------------------
-- UnequipRequest handler
-- -------------------------------------------------------------------------

local function onUnequipRequest(player: Player)
	if not isAlive(player) then return end
	_unequip(player, true)
end

-- -------------------------------------------------------------------------
-- start()
-- -------------------------------------------------------------------------

function EquipService.start(deps: {
	Remotes: any,
	PlayerHoldState: any,
	AmmoLedger: any,
})
	_Remotes = deps.Remotes
	_PlayerHoldState = deps.PlayerHoldState
	_AmmoLedger = deps.AmmoLedger

	_Remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	_Remotes.UnequipRequest.OnServerEvent:Connect(onUnequipRequest)
end

function EquipService.onPlayerRemoving(player: Player)
	equippedWeapons[player] = nil
	lastEquipRequest[player] = nil
end

function EquipService.onCharacterAdded(player: Player)
	-- Respawn clears the equipped weapon (character model is new).
	equippedWeapons[player] = nil
end

return EquipService
