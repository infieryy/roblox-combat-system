--!nonstrict
--[[
	PickupService  (ModuleScript)
	-----------------------------------------------------------------------------
	Authoritative server logic for the First-Person Pickup & Inspection system.

	Responsibilities:
	  * Validate every pickup request (interactable? in range? not already held?).
	  * Hand network ownership of the object to the holder for zero-lag physics.
	  * Build the AlignPosition/AlignOrientation rig (via PhysicsUtil) and let the
	    owning client steer it locally.
	  * Disable held-object <-> character collisions while keeping world collisions.
	  * Clean everything up on drop / death / disconnect / object destruction.

	Security note: the *only* trust boundary that matters is the pickup moment.
	After ownership is transferred the holder's client is physically authoritative
	(this is inherent to Roblox network ownership), so we validate distance and
	eligibility strictly at grant time and re-validate continuously is not needed.
--]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Pickup")
local Config = require(Shared:WaitForChild("PickupConfig"))
local PhysicsUtil = require(Shared:WaitForChild("PhysicsUtil"))
local Net = require(Shared:WaitForChild("Net"))

local PickupService = {}

-- player -> active hold state
local active: { [Player]: any } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getCharacterRefs(player: Player)
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local head = character:FindFirstChild("Head") or root
	return { character = character, root = root, humanoid = humanoid, head = head }
end

local function isInteractable(instance: Instance): boolean
	return CollectionService:HasTag(instance, Config.InteractTag)
		or instance:GetAttribute(Config.InteractAttribute) == true
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

local function cleanup(player: Player, reason: string?)
	local state = active[player]
	if not state then
		return
	end
	active[player] = nil

	-- Stop watching for object/character destruction.
	for _, conn in state.connections do
		conn:Disconnect()
	end

	PhysicsUtil.destroyHoldRig(state.rig)

	for _, weld in state.welds do
		if weld then
			weld:Destroy()
		end
	end

	PhysicsUtil.restoreCollisionGroups(state.originalCollision)
	PhysicsUtil.restoreAnchors(state.originalAnchored)

	local primary = state.primary
	if primary and primary.Parent then
		pcall(function()
			primary:SetNetworkOwnershipAuto()
		end)
	end

	local root = state.root
	if root and root.Parent then
		root:SetAttribute(Config.HeldByAttribute, nil)
	end

	local netPlayer = state.player
	if netPlayer and netPlayer.Parent then
		Net.PickupEnded:FireClient(netPlayer, reason or "dropped")
	end
end

--------------------------------------------------------------------------------
-- Pickup
--------------------------------------------------------------------------------

local function handlePickup(player: Player, target: Instance)
	-- Already holding something -> ignore (drop first).
	if active[player] then
		return
	end
	if typeof(target) ~= "Instance" or not target:IsDescendantOf(workspace) then
		return
	end

	local refs = getCharacterRefs(player)
	if not refs then
		return
	end

	-- Resolve & re-validate the interactable root entirely on the server. We do
	-- NOT trust the client's claim that `target` is interactable.
	local root: Instance?
	if isInteractable(target) then
		root = target
	else
		root = PhysicsUtil.resolvePickupRoot(target, Config.InteractTag, Config.InteractAttribute)
	end
	if not root then
		return
	end

	-- Not already held by someone else.
	if root:GetAttribute(Config.HeldByAttribute) then
		return
	end

	local primary = PhysicsUtil.getPrimaryPart(root)
	if not primary then
		return
	end

	-- Anti-exploit: server-side distance check against the object's geometric
	-- centre (robust to off-centre Blender pivots).
	local boxCFrame = PhysicsUtil.getBoundingBox(root)
	local distance = (boxCFrame.Position - refs.head.Position).Magnitude
	if distance > Config.MaxPickupDistance + Config.ServerDistanceTolerance then
		return
	end

	-- Mass limit (optional).
	if Config.MaxHoldMass > 0 and PhysicsUtil.getMass(root) > Config.MaxHoldMass then
		return
	end

	-- ---- Begin hold ---------------------------------------------------------
	root:SetAttribute(Config.HeldByAttribute, player.UserId)

	local originalAnchored = PhysicsUtil.unanchor(root)
	local welds = PhysicsUtil.weldAssembly(root, primary)
	local originalCollision = PhysicsUtil.setCollisionGroup(root, Config.HeldCollisionGroup)

	-- Hand physics to the holder for zero-lag dragging.
	local ownershipOk = pcall(function()
		primary:SetNetworkOwner(player)
	end)
	if not ownershipOk then
		-- Roll back partial state and bail.
		PhysicsUtil.restoreCollisionGroups(originalCollision)
		for _, weld in welds do
			weld:Destroy()
		end
		PhysicsUtil.restoreAnchors(originalAnchored)
		root:SetAttribute(Config.HeldByAttribute, nil)
		return
	end

	local rig = PhysicsUtil.createHoldRig(root, primary, {
		MaxForce = Config.MaxForce,
		MaxTorque = Config.MaxTorque,
		MaxVelocity = Config.MaxVelocity,
		PositionResponsiveness = Config.PositionResponsiveness,
		OrientationResponsiveness = Config.OrientationResponsiveness,
	})

	local state = {
		player = player,
		root = root,
		primary = primary,
		rig = rig,
		welds = welds,
		originalAnchored = originalAnchored,
		originalCollision = originalCollision,
		connections = {},
	}
	active[player] = state

	-- Auto-drop if the object (or its primary part) is removed mid-hold.
	table.insert(
		state.connections,
		root.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup(player, "object_removed")
			end
		end)
	)
	table.insert(
		state.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then
				cleanup(player, "object_removed")
			end
		end)
	)
	-- Auto-drop on death.
	table.insert(
		state.connections,
		refs.humanoid.Died:Connect(function()
			cleanup(player, "died")
		end)
	)

	-- Tell the owning client which instances to steer.
	Net.PickupGranted:FireClient(player, root, primary, rig.alignPosition, rig.alignOrientation)
end

local function handleDrop(player: Player)
	cleanup(player, "dropped")
end

--------------------------------------------------------------------------------
-- Character / collision-group bookkeeping
--------------------------------------------------------------------------------

local function bindCharacter(character: Model)
	local function apply(part: Instance)
		if part:IsA("BasePart") then
			part.CollisionGroup = Config.CharacterCollisionGroup
		end
	end
	for _, descendant in character:GetDescendants() do
		apply(descendant)
	end
	character.DescendantAdded:Connect(apply)
end

local function bindPlayer(player: Player)
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		bindCharacter(player.Character)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function PickupService.start()
	PhysicsUtil.ensureCollisionGroups(Config.CharacterCollisionGroup, Config.HeldCollisionGroup)

	Net.RequestPickup.OnServerEvent:Connect(handlePickup)
	Net.RequestDrop.OnServerEvent:Connect(handleDrop)

	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		cleanup(player, "left")
	end)
end

return PickupService
