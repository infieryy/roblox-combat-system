--!strict
-- Module: server/EquipService
-- Handles EquipRequest / UnequipRequest. Validates the request, routes through
-- PlayerHoldState (one item at a time), initialises ammo, and attaches the
-- weapon to the character's hand authoritatively (the third-person view; the
-- first-person arms+gun are the client's cosmetic ViewmodelController).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type Context = { [string]: any }

type EquipSession = {
	weapon: Instance,
	primary: BasePart,
	weaponId: string,
	welds: { Instance },
	anchoredSnapshot: { [BasePart]: boolean },
	canCollideSnapshot: { [BasePart]: boolean },
	masslessSnapshot: { [BasePart]: boolean },
}

local EquipService = {}

local ctx: Context = nil :: any
local equips: { [Player]: EquipSession } = {}
local lastEquipAt: { [Player]: number } = {}
local lastUnequipAt: { [Player]: number } = {}

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

local function getHand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") -- R15
		or character:FindFirstChild("Right Arm") -- R6
	if hand and hand:IsA("BasePart") then
		return hand
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function gripCFrame(hand: BasePart): CFrame
	local grip = hand:FindFirstChild("RightGripAttachment")
	if grip and grip:IsA("Attachment") then
		return grip.WorldCFrame
	end
	-- Reasonable default: at the hand, gun pointing where the character faces.
	return hand.CFrame
end

-- Attach the weapon rigidly to the character's hand. Records enough to undo it.
local function attachToHand(player: Player, weapon: Instance, weaponId: string): EquipSession?
	local character = player.Character
	if not character then
		return nil
	end
	local primary = GeometryUtil.getPrimaryPart(weapon)
	local hand = getHand(character)
	if not primary or not hand then
		return nil
	end

	local anchoredSnapshot: { [BasePart]: boolean } = {}
	local canCollideSnapshot: { [BasePart]: boolean } = {}
	local masslessSnapshot: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(weapon) do
		anchoredSnapshot[part] = part.Anchored
		canCollideSnapshot[part] = part.CanCollide
		masslessSnapshot[part] = part.Massless
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
	end

	local welds: { Instance } = {}

	-- Weld loose weapon parts into one assembly (unless it is rigged/animated).
	if weapon:IsA("Model") and not weapon:FindFirstChildWhichIsA("Motor6D", true) then
		local connected: { [BasePart]: boolean } = {}
		for _, part in primary:GetConnectedParts(true) do
			connected[part] = true
		end
		for _, part in GeometryUtil.getParts(weapon) do
			if part ~= primary and not connected[part] then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "EquipWeld"
				weld.Part0 = primary
				weld.Part1 = part
				weld.Parent = primary
				table.insert(welds, weld)
			end
		end
	end

	-- Position then weld the primary to the hand (WeldConstraint preserves the
	-- relative offset at the moment it is created).
	primary.CFrame = gripCFrame(hand)
	local handWeld = Instance.new("WeldConstraint")
	handWeld.Name = "EquipHandWeld"
	handWeld.Part0 = hand
	handWeld.Part1 = primary
	handWeld.Parent = primary
	table.insert(welds, handWeld)

	-- The weapon now rides the character (which the player owns); make ownership
	-- follow for smooth motion.
	ctx.physics.giveOwnership(primary, player)
	weapon:SetAttribute(Config.HeldByAttribute, player.UserId)

	return {
		weapon = weapon,
		primary = primary,
		weaponId = weaponId,
		welds = welds,
		anchoredSnapshot = anchoredSnapshot,
		canCollideSnapshot = canCollideSnapshot,
		masslessSnapshot = masslessSnapshot,
	}
end

-- Detach the weapon and restore it. Does NOT touch PlayerHoldState.
local function detach(player: Player): boolean
	local session = equips[player]
	if not session then
		return false
	end
	equips[player] = nil

	for _, weld in session.welds do
		if weld.Parent then
			weld:Destroy()
		end
	end

	for part, anchored in session.anchoredSnapshot do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
	for part, canCollide in session.canCollideSnapshot do
		if part and part.Parent then
			part.CanCollide = canCollide
		end
	end
	for part, massless in session.masslessSnapshot do
		if part and part.Parent then
			part.Massless = massless
		end
	end

	if session.primary.Parent then
		ctx.physics.returnOwnership(session.primary)
	end
	if session.weapon.Parent then
		session.weapon:SetAttribute(Config.HeldByAttribute, nil)
	end
	return true
end

----------------------------------------------------------------------
-- Public API.
----------------------------------------------------------------------

-- Counterpart teardown for DragService (gun -> prop swap): release the weapon
-- without changing hold state (the caller already switched it).
function EquipService.forceUnequip(player: Player)
	detach(player)
end

-- Full unequip initiated by the player or lifecycle: release + clear hold state.
function EquipService.unequip(player: Player)
	local had = detach(player)
	if had then
		ctx.holdState.clear(player)
		if player.Parent then
			ctx.remotes.EquipResult:FireClient(player, false)
		end
	end
end

function EquipService.clearPlayer(player: Player)
	detach(player)
	lastEquipAt[player] = nil
	lastUnequipAt[player] = nil
end

local function onEquipRequest(player: Player, requested: unknown)
	local now = os.clock()
	local last = lastEquipAt[player]
	if last and (now - last) * 1000 < Config.Security.equipRequestCooldownMs then
		return
	end
	lastEquipAt[player] = now

	if typeof(requested) ~= "Instance" then
		return
	end
	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) or not isAlive(player) then
		return
	end

	local weapon = ItemRegistry.resolve(instance)
	if not weapon or ItemRegistry.classify(weapon) ~= "Weapon" then
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	if not weaponId or not ItemRegistry.getWeaponDef(weaponId) then
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Already equipped by someone else?
	local heldBy = weapon:GetAttribute(Config.HeldByAttribute)
	if heldBy ~= nil and heldBy ~= player.UserId then
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Distance check.
	local head = getHead(player)
	if not head then
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end
	local centre = GeometryUtil.getVisualCenter(weapon)
	if (centre - head.Position).Magnitude > Config.Security.maxEquipDistance then
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end

	-- One-item rule: claim the weapon slot; tear down whatever was held before.
	local previous = ctx.holdState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" then
		ctx.drag.forceRelease(player)
	elseif previous.kind == "Weapon" then
		detach(player) -- swapping guns
	end

	ctx.ammo.onEquip(player, weaponId)

	local session = attachToHand(player, weapon, weaponId)
	if not session then
		-- Could not attach (no hand/primary): roll the hold state back.
		ctx.holdState.clear(player)
		ctx.remotes.EquipResult:FireClient(player, false)
		return
	end
	equips[player] = session

	local ammo = ctx.ammo.get(player, weaponId)
	ctx.remotes.EquipResult:FireClient(player, true, weaponId, ammo)
end

function EquipService.start(context: Context)
	ctx = context

	ctx.remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	ctx.remotes.UnequipRequest.OnServerEvent:Connect(function(player: Player)
		local now = os.clock()
		local last = lastUnequipAt[player]
		if last and (now - last) * 1000 < Config.Security.unequipRequestCooldownMs then
			return
		end
		lastUnequipAt[player] = now
		EquipService.unequip(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		EquipService.clearPlayer(player)
	end)
end

return EquipService
