--!strict
--[[
	EquipService  (server/EquipService.luau → ServerScriptService.Server.EquipService)
	------------------------------------------------------------------------------------
	Handles EquipRequest and UnequipRequest. New system — no equivalent in the
	consensus build.

	Equip pipeline:
	  1. Rate-limit.
	  2. classify(weapon) == "Weapon"; weaponId/def present.
	  3. Distance ≤ Config.Security.maxEquipDistance.
	  4. Not already held by another player.
	  5. PlayerHoldState.setWeapon → if prev was Prop → DragService.forceRelease.
	  6. AmmoLedger.onEquip.
	  7. Attach weapon to character's right hand.
	  8. EquipResult(true, weaponId, ammo) + HoldStateChanged (fired by PlayerHoldState).

	forceUnequip(player) is the public teardown called by DragService when a prop
	is grabbed while a weapon is equipped.
]]

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config          = require(Shared:WaitForChild("Config"))
local ItemRegistry    = require(Shared:WaitForChild("ItemRegistry"))
local GeometryUtil    = require(Shared:WaitForChild("GeometryUtil"))
local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger      = require(script.Parent.AmmoLedger)

local function getDragService()
	return require(script.Parent.DragService)
end

local function getRemotes()
	return require(script.Parent.Remotes).get()
end

local EquipService = {}

-- Per-player rate-limit timestamps.
local lastEquipTime:   { [Player]: number } = {}
local lastUnequipTime: { [Player]: number } = {}

-- Track the WeldConstraint + weld-related cleanup per player.
type EquipSession = {
	weapon: Instance,
	primary: BasePart,
	weld: WeldConstraint,
	connections: { RBXScriptConnection },
}
local equipSessions: { [Player]: EquipSession } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then return nil end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head :: BasePart end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then return root :: BasePart end
	return nil
end

-- Attach the weapon model to the player's right hand.
-- R15: character.RightHand; R6: character["Right Arm"].
-- Returns the WeldConstraint if successful, nil otherwise.
local function attachToHand(weapon: Instance, primary: BasePart, character: Model): WeldConstraint?
	local rightHand = (character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")) :: BasePart?
	if not rightHand or not rightHand:IsA("BasePart") then
		return nil
	end

	-- Unanchor the weapon.
	for _, part in GeometryUtil.getParts(weapon) do
		part.Anchored = false
	end

	-- Move weapon into the character hierarchy (makes it visible to others).
	weapon.Parent = character

	-- Position the primary part relative to the hand.
	-- A CFrame.new(0, 0, -1) offset places it just in front of the hand grip.
	primary.CFrame = rightHand.CFrame * CFrame.new(0, -0.1, -0.6)

	local weld = Instance.new("WeldConstraint")
	weld.Name  = "WeaponEquipWeld"
	weld.Part0 = rightHand
	weld.Part1 = primary
	weld.Parent = primary

	return weld
end

-- Detach weapon from character and return it to Workspace.
local function detachWeapon(session: EquipSession, player: Player)
	for _, conn in session.connections do
		conn:Disconnect()
	end
	if session.weld.Parent then
		session.weld:Destroy()
	end
	if session.weapon.Parent then
		-- Drop at character's feet.
		local head = getHead(player)
		if head and session.primary.Parent then
			session.weapon.Parent = Workspace
			session.primary.CFrame = head.CFrame * CFrame.new(0, -2, -2)
			-- Small downward impulse so it falls naturally.
			session.primary.AssemblyLinearVelocity = Vector3.new(0, -4, 0)
		else
			session.weapon.Parent = Workspace
		end
	end
	session.weapon:SetAttribute(Config.HeldByAttribute, nil)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Equip / unequip
-- ─────────────────────────────────────────────────────────────────────────────

local function doUnequip(player: Player, fireBroadcast: boolean)
	local session = equipSessions[player]
	if not session then
		return
	end
	equipSessions[player] = nil :: any

	detachWeapon(session, player)
	PlayerHoldState.clear(player) -- fires HoldStateChanged("None")

	if fireBroadcast and player.Parent then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
	end
end

local function onEquipRequest(player: Player, requested: unknown)
	local now = os.clock()
	local last = lastEquipTime[player] or 0
	if (now - last) * 1000 < Config.Security.equipRequestCooldownMs then
		return
	end
	lastEquipTime[player] = now

	if typeof(requested) ~= "Instance" then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end
	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	-- Validate item type.
	if ItemRegistry.classify(instance) ~= "Weapon" then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	local weaponId = ItemRegistry.getWeaponId(instance)
	local def = weaponId and ItemRegistry.getWeaponDef(weaponId)
	if not weaponId or not def then
		warn(string.format("[EquipService] Weapon '%s' has no WeaponId or unknown def.", instance.Name))
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	-- Distance check.
	local head = getHead(player)
	if not head then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end
	local weaponCenter = GeometryUtil.getVisualCenter(instance)
	if (weaponCenter - head.Position).Magnitude > Config.Security.maxEquipDistance then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	-- Already held by another player?
	if instance:GetAttribute(Config.HeldByAttribute) ~= nil then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	-- Character reference.
	local character = player.Character
	if not character then
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	-- One-item rule: if currently dragging a prop, force-release it first.
	local prev = PlayerHoldState.setWeapon(player, instance, weaponId)
	if prev.kind == "Prop" then
		getDragService().forceRelease(player)
	end

	-- Attach to hand.
	local weld = attachToHand(instance, primary, character)
	if not weld then
		-- Could not attach (e.g. no right hand bone). Roll back.
		PlayerHoldState.clear(player)
		getRemotes().EquipResult:FireClient(player, false, nil, nil)
		return
	end

	instance:SetAttribute(Config.HeldByAttribute, player.UserId)
	AmmoLedger.onEquip(player, weaponId)
	local ammo = AmmoLedger.get(player, weaponId)

	local session: EquipSession = {
		weapon = instance,
		primary = primary,
		weld = weld,
		connections = {},
	}

	-- Auto-unequip if weapon is removed.
	table.insert(session.connections, instance.AncestryChanged:Connect(function(_, parent)
		if not parent then
			doUnequip(player, true)
		end
	end))

	equipSessions[player] = session

	getRemotes().EquipResult:FireClient(player, true, weaponId, ammo)
end

local function onUnequipRequest(player: Player)
	local now = os.clock()
	local last = lastUnequipTime[player] or 0
	if (now - last) * 1000 < Config.Security.unequipRequestCooldownMs then
		return
	end
	lastUnequipTime[player] = now

	doUnequip(player, true)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Called by DragService when a prop is grabbed while a weapon is equipped.
function EquipService.forceUnequip(player: Player)
	doUnequip(player, true)
end

function EquipService.start()
	local remotes = getRemotes()
	remotes.EquipRequest.OnServerEvent:Connect(onEquipRequest)
	remotes.UnequipRequest.OnServerEvent:Connect(onUnequipRequest)
end

function EquipService.onPlayerRemoving(player: Player)
	doUnequip(player, false)
	lastEquipTime[player]   = nil :: any
	lastUnequipTime[player] = nil :: any
end

function EquipService.onCharacterAdded(player: Player)
	-- Respawn force-unequips.
	doUnequip(player, false)
end

return EquipService
