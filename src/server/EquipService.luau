--!strict
-- Module: EquipService
-- Server-authoritative weapon equip / unequip.

local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.Shared.Config)
local GeometryUtil = require(game.ReplicatedStorage.Shared.GeometryUtil)
local ItemRegistry = require(game.ReplicatedStorage.Shared.ItemRegistry)
local Types = require(game.ReplicatedStorage.Shared.Types)

local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type HoldState = Types.HoldState
type RemotesTable = typeof(require(script.Parent.Remotes).build())

local EquipService = {}

local remotes: RemotesTable? = nil
local dragService: { forceRelease: (Player) -> () }? = nil
local lastEquipRequest: { [Player]: number } = {}
local equippedWelds: { [Player]: { Instance } } = {}

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

local function rateLimitOk(player: Player): boolean
	local now = os.clock() * 1000
	local last = lastEquipRequest[player] or 0
	if now - last < Config.Security.equipRequestCooldownMs then
		return false
	end
	lastEquipRequest[player] = now
	return true
end

local function getRightHand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function detachWeapon(player: Player)
	local welds = equippedWelds[player]
	if welds then
		for _, instance in welds do
			if instance.Parent then
				instance:Destroy()
			end
		end
	end
	equippedWelds[player] = nil
end

local function attachWeapon(player: Player, weapon: Instance)
	local character = player.Character
	if not character then
		return
	end
	local hand = getRightHand(character)
	local primary = GeometryUtil.getPrimaryPart(weapon)
	if not hand or not primary then
		return
	end

	detachWeapon(player)

	for _, part in GeometryUtil.getParts(weapon) do
		part.Anchored = false
		part.CanCollide = false
	end

	local offset = CFrame.new(0, -0.2, -0.8)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "WeaponEquipWeld"
	weld.Part0 = hand
	weld.Part1 = primary
	weld.Parent = hand

	primary.CFrame = hand.CFrame * offset
	equippedWelds[player] = { weld }

	weapon:SetAttribute("EquippedBy", player.UserId)
end

function EquipService.forceUnequip(player: Player)
	local hold = PlayerHoldState.get(player)
	if hold.kind ~= "Weapon" or not hold.instance then
		detachWeapon(player)
		return
	end

	local weapon = hold.instance
	detachWeapon(player)
	if weapon.Parent then
		weapon:SetAttribute("EquippedBy", nil)
		for _, part in GeometryUtil.getParts(weapon) do
			part.CanCollide = true
		end
	end
	PlayerHoldState.clear(player)
	if remotes then
		remotes.EquipResult:FireClient(player, false, nil, nil)
	end
end

local function onEquipRequest(player: Player, requested: unknown)
	if not rateLimitOk(player) then
		return
	end
	if typeof(requested) ~= "Instance" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end
	if not isAlive(player) then
		return
	end

	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) then
		return
	end

	if ItemRegistry.classify(instance) ~= "Weapon" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local weaponId = ItemRegistry.getWeaponId(instance)
	local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
	if not weaponId or not def then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local equippedBy = instance:GetAttribute("EquippedBy")
	if equippedBy ~= nil and equippedBy ~= player.UserId then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local head = getHead(player)
	local primary = GeometryUtil.getPrimaryPart(instance)
	if not head or not primary then
		return
	end

	local centre = GeometryUtil.getVisualCenter(instance)
	local distance = (centre - head.Position).Magnitude - GeometryUtil.getBoundingRadius(instance)
	if distance > Config.Security.maxEquipDistance then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local previous: HoldState = PlayerHoldState.setWeapon(player, instance, weaponId)
	if previous.kind == "Prop" and dragService then
		dragService.forceRelease(player)
	end

	AmmoLedger.onEquip(player, weaponId)
	attachWeapon(player, instance)

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo)
	end
end

function EquipService.setDragService(service: { forceRelease: (Player) -> () })
	dragService = service
end

function EquipService.init(remotesTable: RemotesTable)
	remotes = remotesTable
	remotesTable.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotesTable.UnequipRequest.OnServerEvent:Connect(function(player: Player)
		EquipService.forceUnequip(player)
	end)
end

function EquipService.onPlayerRemoving(player: Player)
	detachWeapon(player)
	lastEquipRequest[player] = nil
end

function EquipService.onCharacterSpawn(player: Player)
	EquipService.forceUnequip(player)
end

return EquipService
