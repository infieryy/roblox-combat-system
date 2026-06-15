--!strict
-- Module: EquipService
-- Handles weapon equip and unequip.
-- Listens for EquipRequest (C→S) and UnequipRequest (C→S).
-- Integrates with PlayerHoldState for the one-item rule and AmmoLedger for ammo init.
--
-- Public API (for cross-service use):
--   EquipService.init(remotes, physicsAuthority, playerHoldState, ammoLedger, forceReleaseFn)
--   EquipService.forceUnequip(player)  -- called by DragService when grabbing a prop

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local EquipService = {}

-- Injected dependencies
local Remotes: any         = nil
local PlayerHoldState: any = nil
local AmmoLedger: any      = nil
local forceReleaseFn: ((Player) -> ())? = nil

-- -------------------------------------------------------------------------
-- Rate limiting
-- -------------------------------------------------------------------------

local lastEquipTime: { [Player]: number } = {}

local function checkCooldown(player: Player): boolean
	local nowMs = os.clock() * 1000
	local last  = lastEquipTime[player] or 0
	if nowMs - last < Config.Security.equipRequestCooldownMs then
		return false
	end
	lastEquipTime[player] = nowMs
	return true
end

-- -------------------------------------------------------------------------
-- Utility
-- -------------------------------------------------------------------------

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then return nil end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then return root end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- -------------------------------------------------------------------------
-- Physical weapon attachment / detachment
-- -------------------------------------------------------------------------

-- Attach the weapon model to the player's right hand (or HumanoidRootPart as fallback).
-- The weapon is re-parented to the character and welded to the hand.
local function attachWeaponToCharacter(weapon: Instance, character: Model)
	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local anchor    = rightHand or character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if not anchor or not anchor:IsA("BasePart") then return end

	local primary = GeometryUtil.getPrimaryPart(weapon)
	if not primary then return end

	-- Unanchor all parts before welding.
	for _, part in GeometryUtil.getParts(weapon) do
		part.Anchored = false
	end

	local weld   = Instance.new("WeldConstraint")
	weld.Name    = "WeaponEquipWeld"
	weld.Part0   = anchor
	weld.Part1   = primary

	-- Position weapon at the hand attachment point.
	primary.CFrame = anchor.CFrame * CFrame.new(0, 0, -1)

	weapon.Parent = character
	weld.Parent   = primary
end

-- Remove the equip weld and detach weapon from the character back into the world.
local function detachWeaponFromCharacter(weapon: Instance, character: Model?)
	if weapon.Parent == character or weapon.Parent == Workspace then
		-- Remove equip welds
		if weapon:IsA("Model") then
			for _, part in GeometryUtil.getParts(weapon) do
				local weld = part:FindFirstChild("WeaponEquipWeld")
				if weld then weld:Destroy() end
			end
		end
		weapon.Parent = Workspace
	end
end

-- -------------------------------------------------------------------------
-- EquipRequest handler
-- -------------------------------------------------------------------------

local function onEquipRequest(player: Player, requested: unknown)
	if not checkCooldown(player) then return end
	if typeof(requested) ~= "Instance" then return end
	local instance = requested :: Instance

	if not instance:IsDescendantOf(Workspace) then return end
	if not isAlive(player) then return end

	-- Walk up ancestry to find the weapon root
	local weapon: Instance = instance
	local node: Instance? = instance
	while node and node ~= Workspace do
		if ItemRegistry.classify(node) == "Weapon" then
			weapon = node
			break
		end
		node = node.Parent
	end

	if ItemRegistry.classify(weapon) ~= "Weapon" then
		Remotes.EquipResult:FireClient(player, false)
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	if not weaponId then
		Remotes.EquipResult:FireClient(player, false)
		return
	end

	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		Remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Distance check
	local head = getHead(player)
	if not head then
		Remotes.EquipResult:FireClient(player, false)
		return
	end
	local weaponCenter = GeometryUtil.getVisualCenter(weapon)
	if (weaponCenter - head.Position).Magnitude > Config.Security.maxEquipDistance then
		Remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Not already held by another player?
	if weapon:GetAttribute(Config.Drag.HeldByAttribute) ~= nil then
		Remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Update hold state; get previous for cross-service teardown.
	local previous = PlayerHoldState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and forceReleaseFn then
		forceReleaseFn(player)
	end

	-- Initialise ammo for this weapon.
	AmmoLedger.onEquip(player, weaponId)
	local ammo = AmmoLedger.get(player, weaponId)

	-- Stamp the weapon so others cannot grab it.
	weapon:SetAttribute(Config.Drag.HeldByAttribute, player.UserId)

	-- Physically attach to character.
	local character = player.Character
	if character then
		attachWeaponToCharacter(weapon, character)
	end

	Remotes.EquipResult:FireClient(player, true, weaponId, ammo)
end

-- -------------------------------------------------------------------------
-- UnequipRequest handler
-- -------------------------------------------------------------------------

local function onUnequipRequest(player: Player)
	local state = PlayerHoldState.get(player)
	if state.kind ~= "Weapon" then return end

	local weapon = state.instance
	PlayerHoldState.clear(player)

	if weapon then
		weapon:SetAttribute(Config.Drag.HeldByAttribute, nil)
		detachWeaponFromCharacter(weapon, player.Character)
	end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

function EquipService.init(
	remotes: any,
	_physicsAuthority: any,
	playerHoldState: any,
	ammoLedger: any,
	onForceRelease: (Player) -> ()
)
	Remotes         = remotes
	PlayerHoldState = playerHoldState
	AmmoLedger      = ammoLedger
	forceReleaseFn  = onForceRelease

	Remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	Remotes.UnequipRequest.OnServerEvent:Connect(onUnequipRequest)
end

-- Called by DragService when a player grabs a prop while a weapon is equipped.
-- weaponInstance is passed directly because by the time this runs, PlayerHoldState
-- already reflects "Prop" (setProp was called before this teardown).
function EquipService.forceUnequip(player: Player, weaponInstance: Instance?)
	local weapon = weaponInstance
	if not weapon then
		-- Fallback for other callers (e.g. death handler) that clear state first.
		local state = PlayerHoldState.get(player)
		if state.kind == "Weapon" then
			weapon = state.instance
		end
	end
	if weapon then
		weapon:SetAttribute(Config.Drag.HeldByAttribute, nil)
		detachWeaponFromCharacter(weapon, player.Character)
	end
end

return EquipService
