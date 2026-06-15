--!strict
-- Module: server/EquipService.luau

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local GeometryUtil = require(ReplicatedStorage.Shared.GeometryUtil)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)
local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

local EquipService = {}

local remotes: {
	EquipRequest: RemoteEvent,
	EquipResult: RemoteEvent,
	UnequipRequest: RemoteEvent,
}? = nil

local dragService: { forceRelease: (Player) -> () }? = nil
local lastEquipRequestAt: { [Player]: number } = {}
local equippedWelds: { [Player]: { WeldConstraint } } = {}
local equippedSnapshots: { [Player]: { [BasePart]: boolean } } = {}

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

local function getRightHand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
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

	local snapshot = equippedSnapshots[player]
	if snapshot then
		for part, anchored in snapshot do
			if part and part.Parent then
				part.Anchored = anchored
			end
		end
	end
	equippedSnapshots[player] = nil
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

	local anchoredSnapshot: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(weapon) do
		anchoredSnapshot[part] = part.Anchored
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
	end
	equippedSnapshots[player] = anchoredSnapshot

	if weapon:IsA("Model") then
		weapon:PivotTo(hand.CFrame * CFrame.new(0, -0.2, -0.4))
	else
		primary.CFrame = hand.CFrame * CFrame.new(0, -0.2, -0.4)
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "EquippedWeaponWeld"
	weld.Part0 = hand
	weld.Part1 = primary
	weld.Parent = hand
	equippedWelds[player] = { weld }
end

function EquipService.forceUnequip(player: Player, skipHoldClear: boolean?)
	local state = PlayerHoldState.get(player)
	if state.kind ~= "Weapon" then
		return
	end
	detachWeapon(player)
	if state.instance and state.instance.Parent then
		state.instance:SetAttribute(Config.HeldByAttribute, nil)
	end
	if not skipHoldClear then
		PlayerHoldState.clear(player)
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
	end
end

local function equipWeapon(player: Player, weapon: Instance, weaponId: string)
	local previous = PlayerHoldState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and dragService then
		dragService.forceRelease(player, true)
	end

	weapon:SetAttribute(Config.HeldByAttribute, player.UserId)
	AmmoLedger.onEquip(player, weaponId)
	attachWeapon(player, weapon)

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo)
	end
end

local function onEquipRequest(player: Player, requested: unknown)
	local now = os.clock()
	local lastAt = lastEquipRequestAt[player] or 0
	if (now - lastAt) * 1000 < Config.Security.equipRequestCooldownMs then
		return
	end
	lastEquipRequestAt[player] = now

	if typeof(requested) ~= "Instance" then
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
	if not isAlive(player) then
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

	if weapon:GetAttribute(Config.HeldByAttribute) ~= nil then
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

	local current = PlayerHoldState.get(player)
	if current.kind == "Weapon" and current.instance == weapon then
		EquipService.forceUnequip(player)
		return
	end

	equipWeapon(player, weapon, weaponId)
end

function EquipService.configure(options: {
	remotes: typeof(remotes),
	dragService: { forceRelease: (Player) -> () },
})
	remotes = options.remotes
	dragService = options.dragService
end

function EquipService.start()
	if not remotes then
		warn("[EquipService] remotes not configured")
		return
	end

	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotes.UnequipRequest.OnServerEvent:Connect(function(player)
		EquipService.forceUnequip(player)
	end)
end

function EquipService.onPlayerRemoving(player: Player)
	lastEquipRequestAt[player] = nil
	EquipService.forceUnequip(player)
end

function EquipService.onCharacterAdded(player: Player)
	EquipService.forceUnequip(player)
end

return EquipService
