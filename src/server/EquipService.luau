--!strict
-- Module: EquipService
-- Authoritative weapon equip / unequip.

local Workspace = game:GetService("Workspace")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local GeometryUtil = require(game:GetService("ReplicatedStorage").Shared.GeometryUtil)
local ItemRegistry = require(game:GetService("ReplicatedStorage").Shared.ItemRegistry)

local AmmoLedger = require(script.Parent.AmmoLedger)
local DragService = require(script.Parent.DragService)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type Remotes = typeof(require(script.Parent.Remotes).build())

local EquipService = {}

local remotes: Remotes? = nil
local equippedWelds: { [Player]: { WeldConstraint } } = {}
local equippedSnapshots: { [Player]: { [BasePart]: { Transparency: number, CanCollide: boolean } } } = {}
local lastEquipRequestAt: { [Player]: number } = {}

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

local function rateLimited(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastEquipRequestAt[player] or 0
	if now - last < Config.Security.equipRequestCooldownMs then
		return true
	end
	lastEquipRequestAt[player] = now
	return false
end

local function getAttachPart(character: Model): BasePart?
	local rightHand = character:FindFirstChild("RightHand")
	if rightHand and rightHand:IsA("BasePart") then
		return rightHand
	end
	local rightArm = character:FindFirstChild("Right Arm")
	if rightArm and rightArm:IsA("BasePart") then
		return rightArm
	end
	return character.PrimaryPart
end

local function hideWeapon(weapon: Instance)
	local snapshot: { [BasePart]: { Transparency: number, CanCollide: boolean } } = {}
	for _, part in GeometryUtil.getParts(weapon) do
		snapshot[part] = {
			Transparency = part.Transparency,
			CanCollide = part.CanCollide,
		}
		part.Transparency = 1
		part.CanCollide = false
	end
	return snapshot
end

local function restoreWeapon(snapshot: { [BasePart]: { Transparency: number, CanCollide: boolean } })
	for part, values in snapshot do
		if part and part.Parent then
			part.Transparency = values.Transparency
			part.CanCollide = values.CanCollide
		end
	end
end

local function attachWeaponToCharacter(player: Player, weapon: Instance)
	local character = player.Character
	if not character then
		return
	end
	local primary = GeometryUtil.getPrimaryPart(weapon)
	local attachPart = getAttachPart(character)
	if not primary or not attachPart then
		return
	end

	for _, part in GeometryUtil.getParts(weapon) do
		part.Anchored = false
	end

	local offset = CFrame.new(0, -0.4, -0.6)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "EquippedWeaponWeld"
	weld.Part0 = attachPart
	weld.Part1 = primary
	weld.Parent = primary

	primary.CFrame = attachPart.CFrame * offset
	equippedWelds[player] = { weld }
end

local function detachWeapon(player: Player)
	local welds = equippedWelds[player]
	if welds then
		for _, weld in welds do
			if weld.Parent then
				weld:Destroy()
			end
		end
	end
	equippedWelds[player] = nil
end

function EquipService.forceUnequip(player: Player)
	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.instance then
		return
	end

	local weapon = hold.instance
	detachWeapon(player)

	local snapshot = equippedSnapshots[player]
	if snapshot then
		restoreWeapon(snapshot)
		equippedSnapshots[player] = nil
	end

	weapon:SetAttribute(Config.Drag.heldByAttribute, nil)
	PlayerHoldState.clear(player)

	if remotes and player.Parent then
		remotes.EquipResult:FireClient(player, false, nil, nil)
	end
end

local function teardownWeaponVisuals(player: Player, weapon: Instance)
	detachWeapon(player)
	local snapshot = equippedSnapshots[player]
	if snapshot then
		restoreWeapon(snapshot)
		equippedSnapshots[player] = nil
	end
	weapon:SetAttribute(Config.Drag.heldByAttribute, nil)
end

local function unequip(player: Player)
	EquipService.forceUnequip(player)
end

local function equip(player: Player, requested: unknown)
	if rateLimited(player) then
		return
	end
	if typeof(requested) ~= "Instance" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end
	if not isAlive(player) then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local weapon = ItemRegistry.resolveFromHit(instance, Workspace)
	if not weapon or ItemRegistry.classify(weapon) ~= "Weapon" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
	if not weaponId or not def then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	if weapon:GetAttribute(Config.Drag.heldByAttribute) ~= nil then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local head = getHead(player)
	local primary = GeometryUtil.getPrimaryPart(weapon)
	if not head or not primary then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local centre = GeometryUtil.getVisualCenter(weapon)
	local radius = GeometryUtil.getBoundingRadius(weapon)
	local distance = (centre - head.Position).Magnitude - radius
	if distance > Config.Security.maxEquipDistance then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local previous = PlayerHoldState.get(player)
	if previous.kind == "Prop" then
		DragService.forceRelease(player)
	elseif previous.kind == "Weapon" and previous.instance then
		teardownWeaponVisuals(player, previous.instance)
	end

	PlayerHoldState.setWeapon(player, weapon, weaponId)

	AmmoLedger.onEquip(player, weaponId)
	equippedSnapshots[player] = hideWeapon(weapon)
	attachWeaponToCharacter(player, weapon)
	weapon:SetAttribute(Config.Drag.heldByAttribute, player.UserId)

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo)
	end
end

function EquipService.start(remoteTable: Remotes)
	remotes = remoteTable
	remoteTable.EquipRequest.OnServerEvent:Connect(equip)
	remoteTable.UnequipRequest.OnServerEvent:Connect(unequip)
end

function EquipService.onPlayerRemoving(player: Player)
	EquipService.forceUnequip(player)
	lastEquipRequestAt[player] = nil
end

function EquipService.onCharacterAdded(player: Player)
	EquipService.forceUnequip(player)
end

return EquipService
