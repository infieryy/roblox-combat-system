--!strict
-- Module: DragService
-- Server-authoritative prop drag system.
-- Ported from the consensus PickupServer with three changes:
--   1. Remote names updated to DragStartRequest / DragEndRequest / DragGranted / DragEnded.
--   2. ItemRegistry classification guard: only "Prop" instances may be dragged.
--   3. Rate-limiting on DragStartRequest (Config.Security.dragRequestCooldownMs).
--   4. Drop impulse clamped to Config.Drag.maxVelocity (§14.3 bug fix).
--   5. PlayerHoldState integration for one-item rule.
--
-- All physics logic (AlignPosition + AlignOrientation rig, leash loop, weld assembly,
-- collision groups, network ownership) is preserved exactly from the consensus build.
--
-- Public API (for cross-service use):
--   DragService.init(remotes, physicsAuthority, playerHoldState, forceUnequipFn)
--   DragService.forceRelease(player)    -- called by EquipService when equipping a weapon
--   DragService.onCharacterAdded(player, character)

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config"))
local Types        = require(Shared:WaitForChild("Types"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

-- -------------------------------------------------------------------------
-- Injected dependencies (set via init)
-- -------------------------------------------------------------------------

local Remotes: any = nil
local PhysicsAuthority: any = nil
local PlayerHoldState: any = nil
local forceUnequipFn: ((Player, Instance?) -> ())? = nil

local DragService = {}

-- -------------------------------------------------------------------------
-- Rig names (deterministic so teardown can always find them)
-- -------------------------------------------------------------------------

local ATTACHMENT_NAME      = "PickupHoldAttachment"
local ALIGN_POSITION_NAME  = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

-- -------------------------------------------------------------------------
-- Per-player session state
-- -------------------------------------------------------------------------

local sessions: { [Player]: Types.DragSession } = {}

-- -------------------------------------------------------------------------
-- Rate limiting
-- -------------------------------------------------------------------------

local lastDragRequestTime: { [Player]: number } = {}

local function checkCooldown(player: Player): boolean
	local nowMs = os.clock() * 1000
	local last = lastDragRequestTime[player] or 0
	if nowMs - last < Config.Security.dragRequestCooldownMs then
		return false
	end
	lastDragRequestTime[player] = nowMs
	return true
end

-- -------------------------------------------------------------------------
-- Utility
-- -------------------------------------------------------------------------

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then return nil end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then return root end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- -------------------------------------------------------------------------
-- Assembly helpers (ported from consensus)
-- -------------------------------------------------------------------------

local function unanchor(target: Instance): { [BasePart]: boolean }
	local original: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(target) do
		original[part] = part.Anchored
		part.Anchored = false
	end
	return original
end

local function restoreAnchors(original: { [BasePart]: boolean })
	for part, anchored in original do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
end

-- Weld all loose parts of a model to its primaryPart so the assembly is one rigid body.
-- Only welds parts not already connected via existing joints.
-- Note (§14.5): Motor6D-rigged models may behave unexpectedly; props should be static meshes.
local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then return welds end

	local connected: { [BasePart]: boolean } = {}
	for _, part in primaryPart:GetConnectedParts(true) do
		connected[part] = true
	end

	for _, part in GeometryUtil.getParts(target) do
		if part ~= primaryPart and not connected[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupWeld"
			weld.Part0 = primaryPart
			weld.Part1 = part
			weld.Parent = primaryPart
			table.insert(welds, weld)
		end
	end
	return welds
end

-- -------------------------------------------------------------------------
-- Hold rig (AlignPosition + AlignOrientation, ported from consensus)
-- -------------------------------------------------------------------------

local function createHoldRig(target: Instance, primaryPart: BasePart): Types.HoldRig
	local mass    = math.max(primaryPart.AssemblyMass, 0.1)
	local radius  = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	-- Place the attachment at the visual (bounding-box) centre so meshes
	-- with an off-centre Blender pivot float naturally centred.
	local centreWorld = GeometryUtil.getVisualCenter(target)
	local attachment  = Instance.new("Attachment")
	attachment.Name   = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primaryPart

	local maxForce  = math.clamp(mass * gravity * Config.Drag.forceMultiplier,  Config.Drag.minForce,  Config.Drag.maxForce)
	local maxTorque = math.clamp(mass * (radius * radius + 1) * Config.Drag.torqueMultiplier, Config.Drag.minTorque, Config.Drag.maxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name             = ALIGN_POSITION_NAME
	alignPosition.Mode             = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0      = attachment
	-- Force applied at COM so an asymmetric mass distribution cannot induce
	-- parasitic spin while dragging (key for irregular Blender imports).
	alignPosition.ApplyAtCenterOfMass  = true
	alignPosition.RigidityEnabled      = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce             = maxForce
	alignPosition.MaxVelocity          = Config.Drag.maxVelocity
	alignPosition.Responsiveness       = Config.Drag.positionResponsiveness
	alignPosition.Position             = centreWorld
	alignPosition.Parent               = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name                = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode                = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0         = attachment
	alignOrientation.RigidityEnabled     = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque           = maxTorque
	alignOrientation.MaxAngularVelocity  = Config.Drag.maxAngularVelocity
	alignOrientation.Responsiveness      = Config.Drag.orientationResponsiveness
	-- Lock to the grab-time orientation (decision #2: props do not rotate).
	-- The client will maintain this goal, not update it per-frame.
	alignOrientation.CFrame             = primaryPart.CFrame.Rotation
	alignOrientation.Parent             = primaryPart

	return {
		attachment       = attachment,
		alignPosition    = alignPosition,
		alignOrientation = alignOrientation,
	}
end

-- -------------------------------------------------------------------------
-- Session teardown (internal — does NOT update PlayerHoldState)
-- -------------------------------------------------------------------------

-- Physical teardown: destroys rig, welds, restores collision/anchor state, returns ownership.
-- applyImpulse: true = gentle forward toss on voluntary drop.
local function tearDownSession(player: Player, applyImpulse: boolean)
	local session = sessions[player]
	if not session then return end
	sessions[player] = nil

	for _, connection in session.connections do
		connection:Disconnect()
	end

	-- Return ownership BEFORE destroying constraints so the physics engine
	-- settles the assembly cleanly under auto-simulation.
	if session.primary.Parent then
		PhysicsAuthority.returnOwnership(session.primary)
	end

	if session.rig.alignPosition.Parent  then session.rig.alignPosition:Destroy()  end
	if session.rig.alignOrientation.Parent then session.rig.alignOrientation:Destroy() end
	if session.rig.attachment.Parent     then session.rig.attachment:Destroy()     end

	for _, weld in session.welds do
		if weld.Parent then weld:Destroy() end
	end

	PhysicsAuthority.restoreGroups(session.collisionSnapshot)
	restoreAnchors(session.anchoredSnapshot)

	if session.object.Parent then
		session.object:SetAttribute(Config.Drag.HeldByAttribute, nil)
	end

	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			-- §14.3 fix: clamp the drop impulse so it cannot exceed maxVelocity.
			local impulseVelocity = head.CFrame.LookVector * Config.Drag.dropImpulseSpeed
			local clamped = impulseVelocity.Magnitude
			if clamped > Config.Drag.maxVelocity then
				impulseVelocity = impulseVelocity.Unit * Config.Drag.maxVelocity
			end
			session.primary.AssemblyLinearVelocity = impulseVelocity
		end
	end
end

-- -------------------------------------------------------------------------
-- Public drop (also updates PlayerHoldState and fires DragEnded)
-- -------------------------------------------------------------------------

local function dropObject(player: Player, applyImpulse: boolean)
	local session = sessions[player]
	if not session then return end
	local obj = session.object

	tearDownSession(player, applyImpulse)
	PlayerHoldState.clear(player)  -- fires HoldStateChanged("None") to client

	if player.Parent and Remotes then
		Remotes.DragEnded:FireClient(player, obj)
	end
end

-- -------------------------------------------------------------------------
-- DragStart handler
-- -------------------------------------------------------------------------

local function onDragStart(player: Player, requested: unknown)
	-- Rate limit
	if not checkCooldown(player) then return end

	-- Type safety
	if typeof(requested) ~= "Instance" then return end
	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) then return end
	if not isAlive(player) then return end

	-- Classify (only Props may be dragged; Weapons use EquipRequest)
	local object = instance
	-- Walk up ancestry to find the tagged/attributed root
	local node: Instance? = instance
	while node and node ~= Workspace do
		local kind = ItemRegistry.classify(node)
		if kind ~= "None" then
			object = node
			break
		end
		node = node.Parent
	end

	if ItemRegistry.classify(object) ~= "Prop" then return end
	if not ItemRegistry.isDraggable(object) then return end

	-- Already held by someone?
	if object:GetAttribute(Config.Drag.HeldByAttribute) ~= nil then return end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then return end

	-- Server-authoritative distance check (bounding-box centre, with latency slack).
	local head = getHead(player)
	if not head then return end
	local centreWorld    = GeometryUtil.getVisualCenter(object)
	local boundingRadius = GeometryUtil.getBoundingRadius(object)
	local distance       = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > Config.Security.maxDragStartDistance then return end

	-- Mass sanity
	if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then return end

	-- Handle existing session or previous weapon hold via PlayerHoldState.
	-- If already dragging, tear down the old session's physics first (without clearing hold state,
	-- since setProp below will overwrite it atomically).
	if sessions[player] then
		tearDownSession(player, false)
	end

	-- Update authoritative hold state; get previous for cross-service teardown.
	local previous = PlayerHoldState.setProp(player, object)
	if previous.kind == "Weapon" and forceUnequipFn then
		-- Pass the weapon Instance directly: by this point PlayerHoldState already
		-- reflects "Prop", so forceUnequip must not re-read hold state.
		forceUnequipFn(player, previous.instance)
	end

	-- Build the drag assembly.
	local anchoredSnapshot  = unanchor(object)
	local welds             = weldAssembly(object, primary)

	if not PhysicsAuthority.giveOwnership(primary, player) then
		-- Roll back if ownership failed.
		for _, w in welds do w:Destroy() end
		restoreAnchors(anchoredSnapshot)
		PlayerHoldState.clear(player)
		return
	end

	local collisionSnapshot = PhysicsAuthority.applyHeldGroup(object)
	local rig               = createHoldRig(object, primary)
	object:SetAttribute(Config.Drag.HeldByAttribute, player.UserId)

	local session: Types.DragSession = {
		object            = object,
		primary           = primary,
		rig               = rig,
		welds             = welds,
		anchoredSnapshot  = anchoredSnapshot,
		collisionSnapshot = collisionSnapshot,
		connections       = {},
		boundingRadius    = boundingRadius,
		breachTime        = 0,
	}
	sessions[player] = session

	-- Auto-drop if the object or primary part is removed mid-hold.
	table.insert(session.connections, object.AncestryChanged:Connect(function(_, parent)
		if not parent then dropObject(player, false) end
	end))
	table.insert(session.connections, primary.AncestryChanged:Connect(function(_, parent)
		if not parent then dropObject(player, false) end
	end))

	-- Hand the owning client the server-built constraints to steer.
	Remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
end

-- -------------------------------------------------------------------------
-- Leash loop (ported from consensus — the real anti-cheat for client-owned parts)
-- -------------------------------------------------------------------------

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < Config.Drag.leashInterval then return end
		local elapsed = accumulator
		accumulator = 0

		for player, session in sessions do
			if not session.primary.Parent
				or not session.primary:IsDescendantOf(Workspace)
				or not isAlive(player)
			then
				dropObject(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				dropObject(player, false)
				continue
			end

			local maxDistance = Config.Drag.maxHoldDistance + session.boundingRadius
			local distance    = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > Config.Drag.leashGracePeriod then
					dropObject(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

-- init must be called from init.server.luau before remotes are connected.
function DragService.init(
	remotes: any,
	physicsAuthority: any,
	playerHoldState: any,
	onForceUnequip: (Player, Instance?) -> ()
)
	Remotes           = remotes
	PhysicsAuthority  = physicsAuthority
	PlayerHoldState   = playerHoldState
	forceUnequipFn    = onForceUnequip

	Remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	Remotes.DragEndRequest.OnServerEvent:Connect(function(player: Player)
		dropObject(player, true)
	end)

	startLeashLoop()
end

-- Called by EquipService when a player equips a weapon while a prop is held.
-- Tears down the physical session only — PlayerHoldState is already updated by EquipService.
function DragService.forceRelease(player: Player)
	local session = sessions[player]
	if not session then return end
	local obj = session.object
	tearDownSession(player, false)
	-- Do NOT call PlayerHoldState.clear — EquipService's setWeapon already owns that.
	if player.Parent and Remotes then
		Remotes.DragEnded:FireClient(player, obj)
	end
end

-- Called from init.server.luau on CharacterAdded.
function DragService.onCharacterAdded(player: Player, _character: Model)
	dropObject(player, false)
end

return DragService
