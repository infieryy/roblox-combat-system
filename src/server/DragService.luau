--!strict
--[[
	DragService  (server/DragService.luau → ServerScriptService.Server.DragService)
	----------------------------------------------------------------------------------
	Handles DragStartRequest and DragEndRequest. Ported from the consensus
	PickupServer — the same proven rig, leash loop, and teardown logic, now
	modularised and integrated with PlayerHoldState + ItemRegistry.

	Changes from consensus:
	  • Trigger is now DragStartRequest (mouse-hold), not E.
	  • classify(prop) == "Prop" guard replaces the old generic Interactable check.
	  • PlayerHoldState.setProp integrates the one-item rule (returns prev hold
	    so we can auto-forceUnequip a gun if necessary).
	  • Per-remote rate limiting (Config.Security.dragRequestCooldownMs).
	  • Cap on drop impulse (maxVelocity guard — §14.3 fix).
	  • Inspect-rotate: AlignOrientation goal is SET ONCE at grab time and
	    never driven per-frame, honouring decision #2.
	  • forceRelease(player) exposed for EquipService to call when a weapon is
	    equipped while a prop is held.
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config          = require(Shared:WaitForChild("Config"))
local Types           = require(Shared:WaitForChild("Types"))
local GeometryUtil    = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry    = require(Shared:WaitForChild("ItemRegistry"))
local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState  = require(script.Parent.PlayerHoldState)

-- Lazy: avoid top-level circular require (DragService ↔ EquipService).
local function getEquipService()
	return require(script.Parent.EquipService)
end

local function getRemotes()
	return require(script.Parent.Remotes).get()
end

local DragService = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Session state
-- ─────────────────────────────────────────────────────────────────────────────

local sessions: { [Player]: Types.DragSession } = {}

-- Per-player rate-limit timestamps (os.clock() in seconds).
local lastDragRequestTime: { [Player]: number } = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────────────────────────────────────

local ATTACHMENT_NAME     = "DragHoldAttachment"
local ALIGN_POSITION_NAME = "DragAlignPosition"
local ALIGN_ORIENT_NAME   = "DragAlignOrientation"

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head :: BasePart
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and root:IsA("BasePart") then
		return root :: BasePart
	end
	return nil
end

local function isAlive(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and (humanoid :: Humanoid).Health > 0
end

-- Unanchor every part in target, returning a snapshot for restoration.
local function unanchor(target: Instance): Types.AnchorSnapshot
	local snapshot: Types.AnchorSnapshot = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.Anchored
		part.Anchored = false
	end
	return snapshot
end

local function restoreAnchors(snapshot: Types.AnchorSnapshot)
	for part, anchored in snapshot do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
end

-- Weld loose parts of a multi-part model into a single rigid assembly so
-- the constraints act on the whole model, not just the primary part.
local function weldAssembly(target: Instance, primary: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end
	-- Skip models that contain Motor6D joints (animated rigs) — welding them
	-- would fight the animator. Draggable props should be static meshes.
	for _, desc in target:GetDescendants() do
		if desc:IsA("Motor6D") then
			return welds
		end
	end

	local connected: { [BasePart]: boolean } = {}
	for _, part in primary:GetConnectedParts(true) do
		connected[part] = true
	end

	for _, part in GeometryUtil.getParts(target) do
		if part ~= primary and not connected[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupWeld"
			weld.Part0 = primary
			weld.Part1 = part
			weld.Parent = primary
			table.insert(welds, weld)
		end
	end
	return welds
end

-- Build the AlignPosition + AlignOrientation rig on the primary part.
-- The attachment sits at the visual centre (Blender-corrected) so the object
-- is dragged from its perceived centre, not its pivot.
-- Decision #2: AlignOrientation goal is set once to the grab-time orientation
-- and is never updated per-frame (no prop rotation while dragging).
local function createHoldRig(target: Instance, primary: BasePart): Types.HoldRig
	local mass    = math.max(primary.AssemblyMass, 0.1)
	local radius  = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	local centreWorld = GeometryUtil.getVisualCenter(target)
	local attachment  = Instance.new("Attachment")
	attachment.Name   = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primary.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primary

	local maxForce  = math.clamp(mass * gravity * Config.Drag.forceMultiplier,  Config.Drag.minForce,  Config.Drag.maxForce)
	local maxTorque = math.clamp(mass * (radius * radius + 1) * Config.Drag.torqueMultiplier, Config.Drag.minTorque, Config.Drag.maxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name                = ALIGN_POSITION_NAME
	alignPosition.Mode                = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0         = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled     = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce            = maxForce
	alignPosition.MaxVelocity         = Config.Drag.maxVelocity
	alignPosition.Responsiveness      = Config.Drag.positionResponsiveness
	alignPosition.Position            = centreWorld
	alignPosition.Parent              = primary

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name                 = ALIGN_ORIENT_NAME
	alignOrientation.Mode                 = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0          = attachment
	alignOrientation.RigidityEnabled      = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque            = maxTorque
	alignOrientation.MaxAngularVelocity   = Config.Drag.maxAngularVelocity
	alignOrientation.Responsiveness       = Config.Drag.orientationResponsiveness
	-- Grab-time orientation: never overwritten (decision #2).
	alignOrientation.CFrame              = primary.CFrame.Rotation
	alignOrientation.Parent              = primary

	return {
		attachment      = attachment,
		alignPosition   = alignPosition,
		alignOrientation = alignOrientation,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Drop / teardown
-- ─────────────────────────────────────────────────────────────────────────────

local function dropObject(player: Player, applyImpulse: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil :: any

	for _, connection in session.connections do
		connection:Disconnect()
	end

	-- Return ownership BEFORE destroying constraints so the engine settles
	-- the assembly cleanly.
	if session.primary.Parent then
		PhysicsAuthority.returnOwnership(session.primary)
	end

	if session.rig.alignPosition.Parent then
		session.rig.alignPosition:Destroy()
	end
	if session.rig.alignOrientation.Parent then
		session.rig.alignOrientation:Destroy()
	end
	if session.rig.attachment.Parent then
		session.rig.attachment:Destroy()
	end

	for _, weld in session.welds do
		if weld.Parent then
			weld:Destroy()
		end
	end

	PhysicsAuthority.restoreGroups(session.collisionSnapshot)
	restoreAnchors(session.anchoredSnapshot)

	if session.object.Parent then
		session.object:SetAttribute(Config.HeldByAttribute, nil)
	end

	-- Emergent fling: let the object retain the velocity it had from the
	-- AlignPosition constraint. The optional drop impulse is a small extra
	-- nudge in the look direction, clamped to maxVelocity (§14.3 fix).
	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			local impulse = head.CFrame.LookVector * Config.Drag.dropImpulseSpeed
			local combined = session.primary.AssemblyLinearVelocity + impulse
			if combined.Magnitude > Config.Drag.maxVelocity then
				combined = combined.Unit * Config.Drag.maxVelocity
			end
			session.primary.AssemblyLinearVelocity = combined
		end
	end

	if player.Parent then
		getRemotes().DragEnded:FireClient(player, session.object)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Leash loop (anti-cheat for client-owned physics)
-- ─────────────────────────────────────────────────────────────────────────────

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < Config.Drag.leashInterval then
			return
		end
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
			local distance = (session.primary.Position - head.Position).Magnitude
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Pickup handler
-- ─────────────────────────────────────────────────────────────────────────────

local function onDragStart(player: Player, requested: unknown)
	-- Rate limiting.
	local now = os.clock()
	local last = lastDragRequestTime[player] or 0
	if (now - last) * 1000 < Config.Security.dragRequestCooldownMs then
		return
	end
	lastDragRequestTime[player] = now

	-- One prop at a time.
	if sessions[player] then
		return
	end

	if typeof(requested) ~= "Instance" then
		return
	end
	local instance = requested :: Instance
	if not instance:IsDescendantOf(Workspace) then
		return
	end
	if not isAlive(player) then
		return
	end

	-- Never trust the client's reference; validate item type server-side.
	local kind = ItemRegistry.classify(instance)
	if kind ~= "Prop" then
		-- Walk ancestry in case the client sent a sub-part.
		local node: Instance? = instance.Parent
		while node and node ~= Workspace do
			if ItemRegistry.classify(node) == "Prop" then
				instance = node
				kind = "Prop"
				break
			end
			node = node.Parent
		end
		if kind ~= "Prop" then
			return
		end
	end

	if not ItemRegistry.isDraggable(instance) then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(instance)
	if not primary or primary.Anchored then
		return
	end

	local head = getHead(player)
	if not head then
		return
	end

	-- Server-authoritative distance check (uses visual centre so Blender meshes
	-- with off-centre pivots are measured correctly), with latency slack.
	local centreWorld   = GeometryUtil.getVisualCenter(instance)
	local boundingRadius = GeometryUtil.getBoundingRadius(instance)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > Config.Security.maxDragStartDistance then
		return
	end

	-- Mass sanity guard.
	if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then
		return
	end

	-- One-item rule: setProp returns the previous hold so we can auto-teardown.
	local prev = PlayerHoldState.setProp(player, instance)
	if prev.kind == "Weapon" then
		-- Lazy require: EquipService is loaded by the time any event fires.
		getEquipService().forceUnequip(player)
	end

	-- Commit. Order: unanchor → weld (so AssemblyMass is correct) → ownership → rig.
	local anchoredSnapshot = unanchor(instance)
	local welds = weldAssembly(instance, primary)

	if not PhysicsAuthority.giveOwnership(primary, player) then
		-- Roll back.
		for _, weld in welds do
			weld:Destroy()
		end
		restoreAnchors(anchoredSnapshot)
		PlayerHoldState.clear(player)
		return
	end

	local collisionSnapshot = PhysicsAuthority.applyHeldGroup(instance)
	local rig = createHoldRig(instance, primary)
	instance:SetAttribute(Config.HeldByAttribute, player.UserId)

	local session: Types.DragSession = {
		object            = instance,
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

	-- Auto-drop if the object is removed mid-hold.
	table.insert(session.connections, instance.AncestryChanged:Connect(function(_, parent)
		if not parent then
			dropObject(player, false)
		end
	end))
	table.insert(session.connections, primary.AncestryChanged:Connect(function(_, parent)
		if not parent then
			dropObject(player, false)
		end
	end))

	-- Hand the owning client the constraint references so it can steer locally.
	getRemotes().DragGranted:FireClient(player, instance, primary, rig.alignPosition, rig.alignOrientation)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Called by EquipService when a weapon is equipped while a prop is held.
function DragService.forceRelease(player: Player)
	if sessions[player] then
		dropObject(player, false)
	end
	-- Clear any stale hold state (may already be cleared by EquipService).
	-- We only clear if we were actually the ones holding something.
end

-- Wires remote events and starts the leash loop.
function DragService.start()
	local remotes = getRemotes()

	remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remotes.DragEndRequest.OnServerEvent:Connect(function(player: Player)
		if sessions[player] then
			dropObject(player, true) -- apply drop impulse (fling)
			PlayerHoldState.clear(player)
		end
	end)

	startLeashLoop()
end

-- Called from lifecycle hooks when a player dies or respawns.
function DragService.dropOnDeath(player: Player)
	dropObject(player, false)
end

-- Called from lifecycle hooks when a player leaves.
function DragService.onPlayerRemoving(player: Player)
	dropObject(player, false)
	lastDragRequestTime[player] = nil :: any
end

-- Called when a character is added (respawn clears any hold).
function DragService.onCharacterAdded(player: Player, character: Model)
	dropObject(player, false)
end

return DragService
