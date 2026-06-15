--!strict
-- Module: server/EquipService
-- Handles EquipRequest / UnequipRequest (BLUEPRINT.md §10.6, NEW). Validates the
-- target is a weapon in range, routes the one-item rule through PlayerHoldState
-- (auto-releasing a held prop), seeds the AmmoLedger, and attaches an
-- authoritative server-side weapon model to the character when an asset exists.

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local ATTR = Config.Attributes

local EquipService = {}

local remotes: any = nil
local holdState: any = nil
local ammo: any = nil
local dragService: any = nil

-- Per-player attached server model + connection bookkeeping.
type EquipRecord = { weaponId: string, model: Model? }
local equipped: { [Player]: EquipRecord } = {}
local lastEquipRequest: { [Player]: number } = {}
local lastUnequipRequest: { [Player]: number } = {}

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

-- Optional authoritative world model. Designers may drop a template Model named
-- after the weaponId (or its viewmodelName) into ServerStorage.WeaponModels or
-- ReplicatedStorage.WeaponModels. If present it is cloned and welded to the
-- character's right hand so OTHER players see the gun. If absent we proceed with
-- just the attribute stamp (the holder still sees the client viewmodel).
local function findWeaponTemplate(weaponId: string): Model?
	local def = ItemRegistry.getWeaponDef(weaponId)
	for _, container in { ServerStorage:FindFirstChild("WeaponModels"), ReplicatedStorage:FindFirstChild("WeaponModels") } do
		if container then
			local byId = container:FindFirstChild(weaponId)
			if byId and byId:IsA("Model") then
				return byId
			end
			if def then
				local byName = container:FindFirstChild(def.viewmodelName)
				if byName and byName:IsA("Model") then
					return byName
				end
			end
		end
	end
	return nil
end

local function attachWeapon(player: Player, weaponId: string): Model?
	local character = player.Character
	if not character then
		return nil
	end

	local template = findWeaponTemplate(weaponId)
	if not template then
		return nil
	end

	local hand = character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
		or character.PrimaryPart
	if not (hand and hand:IsA("BasePart")) then
		return nil
	end

	local clone = template:Clone()
	local primary = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if not primary then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = primary

	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Massless = true
			part.CollisionGroup = Config.CollisionGroups.characters
		end
	end

	clone:PivotTo(hand.CFrame * CFrame.new(0, -0.2, -0.6))
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = primary
	weld.Parent = primary
	clone.Parent = character
	return clone
end

-- Detach the server weapon model WITHOUT touching hold state (cross-service
-- teardown contract). Called both on normal unequip and on a swap.
local function teardownEquip(player: Player)
	local record = equipped[player]
	if not record then
		return
	end
	equipped[player] = nil
	if record.model and record.model.Parent then
		record.model:Destroy()
	end
	local character = player.Character
	if character then
		character:SetAttribute(ATTR.equippedWeaponId, nil)
	end
end

-- Public: tear down the equip WITHOUT clearing hold state. Called by DragService
-- when a prop grab supersedes a held weapon (caller already set hold = Prop).
function EquipService.forceUnequip(player: Player)
	teardownEquip(player)
end

local function onEquipRequest(player: Player, requested: unknown)
	-- §14.2 rate limit.
	local now = os.clock()
	local last = lastEquipRequest[player]
	if last and (now - last) * 1000 < Config.Security.equipRequestCooldownMs then
		return
	end
	lastEquipRequest[player] = now

	if typeof(requested) ~= "Instance" then
		remotes.EquipResult:FireClient(player, false)
		return
	end
	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) or not isAlive(player) then
		remotes.EquipResult:FireClient(player, false)
		return
	end

	local weapon = ItemRegistry.resolve(instance)
	if not weapon or ItemRegistry.classify(weapon) ~= "Weapon" then
		remotes.EquipResult:FireClient(player, false)
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	local def = weaponId and ItemRegistry.getWeaponDef(weaponId)
	if not weaponId or not def then
		remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Distance check.
	local head = getHead(player)
	if not head then
		remotes.EquipResult:FireClient(player, false)
		return
	end
	local primary = weapon:IsA("Model") and (weapon.PrimaryPart or weapon:FindFirstChildWhichIsA("BasePart"))
		or (weapon:IsA("BasePart") and weapon)
	local refPosition = primary and (primary :: BasePart).Position or head.Position
	if (refPosition - head.Position).Magnitude > Config.Security.maxEquipDistance then
		remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Not already equipped by another player.
	local heldBy = weapon:GetAttribute(ATTR.heldBy)
	if heldBy ~= nil and heldBy ~= player.UserId then
		remotes.EquipResult:FireClient(player, false)
		return
	end

	-- Already holding this exact weapon? No-op success.
	local current = holdState.get(player)
	if current.kind == "Weapon" and current.instance == weapon then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo.get(player, weaponId))
		return
	end

	-- Commit: authoritative hold state + one-item swap (auto-release a prop).
	local previous = holdState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and dragService then
		dragService.forceRelease(player)
	end

	-- Replace any prior weapon attachment, then attach this one.
	teardownEquip(player)
	ammo.onEquip(player, weaponId)
	local model = attachWeapon(player, weaponId)
	equipped[player] = { weaponId = weaponId, model = model }
	local character = player.Character
	if character then
		character:SetAttribute(ATTR.equippedWeaponId, weaponId)
	end

	remotes.EquipResult:FireClient(player, true, weaponId, ammo.get(player, weaponId))
end

local function onUnequipRequest(player: Player)
	local now = os.clock()
	local last = lastUnequipRequest[player]
	if last and (now - last) * 1000 < Config.Security.unequipRequestCooldownMs then
		return
	end
	lastUnequipRequest[player] = now

	local current = holdState.get(player)
	if current.kind ~= "Weapon" then
		return
	end
	teardownEquip(player)
	holdState.clear(player)
end

function EquipService.dropPlayer(player: Player)
	teardownEquip(player)
end

function EquipService.cleanupPlayer(player: Player)
	teardownEquip(player)
	lastEquipRequest[player] = nil
	lastUnequipRequest[player] = nil
end

function EquipService.init(deps: { remotes: any, holdState: any, ammo: any, dragService: any })
	remotes = deps.remotes
	holdState = deps.holdState
	ammo = deps.ammo
	dragService = deps.dragService

	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotes.UnequipRequest.OnServerEvent:Connect(onUnequipRequest)
end

return EquipService
