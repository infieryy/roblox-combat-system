--!strict
-- Module: Authoritative weapon equip/unequip service.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger = require(script.Parent.AmmoLedger)
type RemotesModule = typeof(require(script.Parent.Remotes))
type RemoteBundle = RemotesModule.RemoteBundle

type DragServiceContract = {
	forceRelease: (player: Player) -> (),
}

type EquipSession = {
	weapon: Instance,
	weaponId: string,
	primary: BasePart,
	welds: { WeldConstraint },
	canCollideSnapshot: { [BasePart]: boolean },
	masslessSnapshot: { [BasePart]: boolean },
}

local EquipService = {}

local remotes: RemoteBundle? = nil
local dragService: DragServiceContract? = nil

local sessions: { [Player]: EquipSession } = {}
local weaponOwners: { [Instance]: Player } = {}
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
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getEquipAnchor(character: Model): BasePart?
	local preferred = { "RightHand", "Right Arm", "HumanoidRootPart", "UpperTorso" }
	for _, name in preferred do
		local node = character:FindFirstChild(name)
		if node and node:IsA("BasePart") then
			return node
		end
	end
	return character.PrimaryPart
end

local function snapshotPhysics(target: Instance): ({ [BasePart]: boolean }, { [BasePart]: boolean })
	local collidable: { [BasePart]: boolean } = {}
	local massless: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(target) do
		collidable[part] = part.CanCollide
		massless[part] = part.Massless
		part.CanCollide = false
		part.Massless = true
	end
	return collidable, massless
end

local function restorePhysics(collidable: { [BasePart]: boolean }, massless: { [BasePart]: boolean })
	for part, value in collidable do
		if part and part.Parent then
			part.CanCollide = value
		end
	end
	for part, value in massless do
		if part and part.Parent then
			part.Massless = value
		end
	end
end

local function buildAttachWelds(character: Model, weapon: Instance, primary: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	local anchor = getEquipAnchor(character)
	if not anchor then
		return welds
	end

	primary.CFrame = anchor.CFrame * CFrame.new(0, -0.5, -1)

	local rootWeld = Instance.new("WeldConstraint")
	rootWeld.Name = "WeaponEquipWeld"
	rootWeld.Part0 = anchor
	rootWeld.Part1 = primary
	rootWeld.Parent = anchor
	table.insert(welds, rootWeld)

	if weapon:IsA("Model") then
		for _, part in GeometryUtil.getParts(weapon) do
			if part ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "WeaponInternalWeld"
				weld.Part0 = primary
				weld.Part1 = part
				weld.Parent = primary
				table.insert(welds, weld)
			end
		end
	end

	return welds
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local prev = lastEquipRequestAt[player]
	lastEquipRequestAt[player] = now
	if not prev then
		return false
	end
	return (now - prev) * 1000 < Config.Security.equipRequestCooldownMs
end

function EquipService.forceUnequip(player: Player)
	local session = sessions[player]
	if not session then
		return
	end

	sessions[player] = nil
	weaponOwners[session.weapon] = nil

	for _, weld in session.welds do
		if weld.Parent then
			weld:Destroy()
		end
	end

	restorePhysics(session.canCollideSnapshot, session.masslessSnapshot)
	session.weapon:SetAttribute(Config.Drag.weaponHeldByAttribute, nil)

	if session.weapon.Parent and player.Character then
		local anchor = getEquipAnchor(player.Character)
		if anchor then
			local dropCF = anchor.CFrame * CFrame.new(0, -1, -2)
			if session.weapon:IsA("Model") then
				session.weapon:PivotTo(dropCF)
			elseif session.weapon:IsA("BasePart") then
				session.weapon.CFrame = dropCF
			end
		end
		session.weapon.Parent = Workspace
	end
end

local function rejectEquip(player: Player)
	if remotes then
		remotes.EquipResult:FireClient(player, false, nil, nil)
	end
end

local function acceptEquip(player: Player, weaponId: string, ammo: number)
	if remotes then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo)
	end
end

local function onEquipRequest(player: Player, requested: unknown)
	if isRateLimited(player) then
		rejectEquip(player)
		return
	end
	if typeof(requested) ~= "Instance" then
		rejectEquip(player)
		return
	end

	local weapon = requested :: Instance
	if not weapon:IsDescendantOf(Workspace) then
		rejectEquip(player)
		return
	end
	if ItemRegistry.classify(weapon) ~= "Weapon" then
		rejectEquip(player)
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	if not weaponId then
		rejectEquip(player)
		return
	end
	local def = ItemRegistry.getWeaponDef(weaponId)
	if not def then
		rejectEquip(player)
		return
	end

	local owner = weaponOwners[weapon]
	if owner and owner ~= player then
		rejectEquip(player)
		return
	end

	local heldBy = weapon:GetAttribute(Config.Drag.weaponHeldByAttribute)
	if heldBy and heldBy ~= player.UserId then
		rejectEquip(player)
		return
	end

	local head = getHead(player)
	if not head then
		rejectEquip(player)
		return
	end

	local visualCenter = GeometryUtil.getVisualCenter(weapon)
	local distance = (visualCenter - head.Position).Magnitude
	if distance > Config.Security.maxEquipDistance then
		rejectEquip(player)
		return
	end

	local primary = GeometryUtil.getPrimaryPart(weapon)
	if not primary then
		rejectEquip(player)
		return
	end

	local character = player.Character
	if not character then
		rejectEquip(player)
		return
	end

	local previous = PlayerHoldState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and dragService then
		dragService.forceRelease(player)
	elseif previous.kind == "Weapon" then
		EquipService.forceUnequip(player)
	end

	local collidableSnapshot, masslessSnapshot = snapshotPhysics(weapon)
	local welds = buildAttachWelds(character, weapon, primary)
	weapon:SetAttribute(Config.Drag.weaponHeldByAttribute, player.UserId)
	weaponOwners[weapon] = player

	local session: EquipSession = {
		weapon = weapon,
		weaponId = weaponId,
		primary = primary,
		welds = welds,
		canCollideSnapshot = collidableSnapshot,
		masslessSnapshot = masslessSnapshot,
	}
	sessions[player] = session

	AmmoLedger.onEquip(player, weaponId)
	local ammo = AmmoLedger.get(player, weaponId)
	acceptEquip(player, weaponId, ammo)
end

local function onUnequipRequest(player: Player)
	local current = PlayerHoldState.get(player)
	if current.kind ~= "Weapon" then
		return
	end

	EquipService.forceUnequip(player)
	PlayerHoldState.clear(player)
end

function EquipService.getEquipped(player: Player): (Instance?, string?)
	local session = sessions[player]
	if not session then
		return nil, nil
	end
	return session.weapon, session.weaponId
end

function EquipService.start(remoteBundle: RemoteBundle, drag: DragServiceContract)
	remotes = remoteBundle
	dragService = drag
	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotes.UnequipRequest.OnServerEvent:Connect(onUnequipRequest)
end

function EquipService.cleanupPlayer(player: Player)
	EquipService.forceUnequip(player)
	lastEquipRequestAt[player] = nil
end

return EquipService
