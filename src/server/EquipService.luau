--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local PlayerHoldState = require(script.Parent:WaitForChild("PlayerHoldState"))
local AmmoLedger = require(script.Parent:WaitForChild("AmmoLedger"))

local EquipService = {}

local remotes: any = nil
local dragService: any = nil

local equippedByPlayer: { [Player]: Instance } = {}
local ownerByWeapon: { [Instance]: Player } = {}

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

local function releaseOwnership(player: Player)
	local weapon = equippedByPlayer[player]
	if not weapon then
		return
	end
	equippedByPlayer[player] = nil
	ownerByWeapon[weapon] = nil
	weapon:SetAttribute("EquippedByUserId", nil)
end

function EquipService.forceUnequip(player: Player, reason: string?, skipHoldStateClear: boolean?)
	releaseOwnership(player)
	if not skipHoldStateClear then
		local hold = PlayerHoldState.get(player)
		if hold.kind == "Weapon" then
			PlayerHoldState.clear(player)
		end
	end
	remotes.EquipResult:FireClient(player, false, nil, nil, reason or "unequipped")
end

local function onEquipRequest(player: Player, requested: any)
	if typeof(requested) ~= "Instance" then
		remotes.EquipResult:FireClient(player, false, nil, nil, "invalid_target")
		return
	end

	local weapon = ItemRegistry.resolveItemRoot(requested)
	if not weapon or ItemRegistry.classify(weapon) ~= "Weapon" then
		remotes.EquipResult:FireClient(player, false, nil, nil, "not_weapon")
		return
	end

	local weaponId = ItemRegistry.getWeaponId(weapon)
	local weaponDef = weaponId and ItemRegistry.getWeaponDef(weaponId) or nil
	if not weaponId or not weaponDef then
		remotes.EquipResult:FireClient(player, false, nil, nil, "missing_weapon_id")
		return
	end

	local owner = ownerByWeapon[weapon]
	if owner and owner ~= player then
		remotes.EquipResult:FireClient(player, false, nil, nil, "taken")
		return
	end

	local head = getHead(player)
	if not head then
		remotes.EquipResult:FireClient(player, false, nil, nil, "no_character")
		return
	end

	local boxCF = GeometryUtil.getBoundingBox(weapon)
	local distance = (boxCF.Position - head.Position).Magnitude
	if distance > Config.Validation.maxEquipDistance then
		remotes.EquipResult:FireClient(player, false, nil, nil, "too_far")
		return
	end

	local previous = PlayerHoldState.setWeapon(player, weapon, weaponId)
	if previous.kind == "Prop" and dragService then
		dragService.forceRelease(player, "equipped_weapon")
	end

	releaseOwnership(player)
	equippedByPlayer[player] = weapon
	ownerByWeapon[weapon] = player
	weapon:SetAttribute("EquippedByUserId", player.UserId)

	local ammo = AmmoLedger.onEquip(player, weaponId)
	remotes.EquipResult:FireClient(player, true, weaponId, ammo, "equipped")
end

function EquipService.getEquippedWeapon(player: Player): Instance?
	return equippedByPlayer[player]
end

function EquipService.setDragService(service: any)
	dragService = service
end

function EquipService.start(remoteMap: any)
	remotes = remoteMap
	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	Players.PlayerRemoving:Connect(function(player)
		releaseOwnership(player)
	end)
end

return EquipService
