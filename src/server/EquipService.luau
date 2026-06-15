--!strict
-- Module: EquipService
-- Handles weapon equip/unequip requests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local Remotes = require(script.Parent.Remotes)
local AmmoLedger = require(script.Parent.AmmoLedger)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

local EquipService = {}

local remotes: Remotes.RemotesTable? = nil
local lastRequestAt: { [Player]: number } = {}
local dragForceRelease: ((player: Player) -> ())? = nil
local equippedByInstance: { [Instance]: Player } = {}

function EquipService.setDragForceRelease(callback: (player: Player) -> ())
	dragForceRelease = callback
end

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

local function canRequest(player: Player): boolean
	local now = os.clock()
	local last = lastRequestAt[player] or 0
	if (now - last) * 1000 < Config.Security.equipRequestCooldownMs then
		return false
	end
	lastRequestAt[player] = now
	return true
end

local function detachWeapon(weapon: Instance)
	local primary = GeometryUtil.getPrimaryPart(weapon)
	if primary then
		primary.Anchored = true
	end
	for _, part in GeometryUtil.getParts(weapon) do
		part.CanCollide = true
	end
	equippedByInstance[weapon] = nil
end

local function attachWeaponToCharacter(player: Player, weapon: Instance)
	local character = player.Character
	if not character then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(weapon)
	if not primary then
		return
	end

	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if rightHand and rightHand:IsA("BasePart") then
		weapon:PivotTo(rightHand.CFrame * CFrame.new(0, -0.5, -0.8))
	else
		local head = getHead(player)
		if head then
			weapon:PivotTo(head.CFrame * CFrame.new(0.4, -0.6, -1.2))
		end
	end

	for _, part in GeometryUtil.getParts(weapon) do
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
	end

	local weldTarget = if rightHand and rightHand:IsA("BasePart") then rightHand else primary
	local weld = Instance.new("WeldConstraint")
	weld.Name = "WeaponEquipWeld"
	weld.Part0 = weldTarget
	weld.Part1 = primary
	weld.Parent = primary

	equippedByInstance[weapon] = player
end

function EquipService.forceUnequip(player: Player)
	local state = PlayerHoldState.get(player)
	if state.kind ~= "Weapon" or not state.instance then
		return
	end

	local weapon = state.instance
	detachWeapon(weapon)

	if weapon.Parent then
		local head = getHead(player)
		if head then
			weapon:PivotTo(head.CFrame * CFrame.new(0, -2, -3))
		end
	end

	PlayerHoldState.clear(player)
end

local function unequip(player: Player)
	EquipService.forceUnequip(player)
	if remotes then
		remotes.EquipResult:FireClient(player, false, nil, nil)
	end
end

local function onEquipRequest(player: Player, requested: unknown)
	if not canRequest(player) then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	if typeof(requested) ~= "Instance" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local weapon = requested :: Instance
	if not weapon:IsDescendantOf(Workspace) or not isAlive(player) then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local resolved = ItemRegistry.resolveFromHit(weapon, Workspace)
	if not resolved or ItemRegistry.classify(resolved) ~= "Weapon" then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end
	weapon = resolved

	local weaponId = ItemRegistry.getWeaponId(weapon)
	local def = if weaponId then ItemRegistry.getWeaponDef(weaponId) else nil
	if not weaponId or not def then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local existingHolder = equippedByInstance[weapon]
	if existingHolder and existingHolder ~= player then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local head = getHead(player)
	if not head then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local centre = GeometryUtil.getVisualCenter(weapon)
	local distance = (centre - head.Position).Magnitude
	if distance > Config.Security.maxEquipDistance then
		if remotes then
			remotes.EquipResult:FireClient(player, false, nil, nil)
		end
		return
	end

	local previous = PlayerHoldState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and dragForceRelease then
		dragForceRelease(player)
	end

	AmmoLedger.onEquip(player, weaponId)
	attachWeaponToCharacter(player, weapon)

	local ammo = AmmoLedger.get(player, weaponId)
	if remotes then
		remotes.EquipResult:FireClient(player, true, weaponId, ammo)
	end
end

function EquipService.onPlayerRemoving(player: Player)
	EquipService.forceUnequip(player)
	lastRequestAt[player] = nil
end

function EquipService.onCharacterAdded(player: Player)
	EquipService.forceUnequip(player)
end

function EquipService.start(remoteTable: Remotes.RemotesTable)
	remotes = remoteTable
	remoteTable.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remoteTable.UnequipRequest.OnServerEvent:Connect(function(player)
		unequip(player)
	end)
end

return EquipService
