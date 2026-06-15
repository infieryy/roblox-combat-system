--!strict
--[[
	PickupServer  (Script -> ServerScriptService)
	===========================================================================
	MASTER CONSENSUS BUILD of the First-Person Pickup & Inspection system.

	This is a single, self-contained authoritative server script. It is the
	synthesised "best of" 10 independently generated implementations:

	  * Architecture (the smooth-feel winner): the server validates a request,
	    transfers network ownership of the assembly to the holder, builds a
	    modern AlignPosition / AlignOrientation rig and then lets the OWNING
	    CLIENT steer the constraint goals locally every frame. That means the
	    drag is simulated on the holder's own machine = zero perceived lag,
	    and the resulting motion replicates to the server and every other
	    player for free. No per-frame remotes are needed.

	  * Blender-safe holding: the object is carried by its *visual bounding-box
	    centre* (computed from real geometry via Model:GetBoundingBox), with a
	    dynamic pivot-correction heuristic, so meshes imported from Blender with
	    an off-centre origin/pivot never hover "offset weirdly". The linear
	    force is applied at the centre of mass (ApplyAtCenterOfMass) so an
	    asymmetric COM cannot induce a parasitic spin while being dragged.

	  * Anti-fling / anti-cheat: forces and torques are finite and scaled by
	    mass, velocities are capped, and a leash loop (with a short grace
	    period) force-drops anything an exploiter drives too far. Held objects
	    are isolated from characters with collision groups.

	Authoring an interactable: tag a Model or BasePart with the CollectionService
	tag "Interactable", OR set a boolean attribute "Interactable = true" on it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------------
-- Configuration (kept inline so this is genuinely ONE master script).
-- The few client-relevant values (Tag/Attribute/keys/distances) are mirrored
-- in FirstPersonPickupClient and must be kept in sync if changed.
----------------------------------------------------------------------

local Config = {
	-- Detection ------------------------------------------------------------
	Tag = "Interactable",
	Attribute = "Interactable",
	-- Stamped on a held object so re-entrancy guards and other systems can
	-- tell who currently owns it.
	HeldByAttribute = "PickupHeldBy",

	-- Reach / distances (studs) -------------------------------------------
	MaxPickupDistance = 12,
	-- Slack added to the pickup distance check to forgive latency between the
	-- client's aim frame and the request arriving on the server.
	ServerDistanceTolerance = 4,
	-- Hard leash: a held object may sit at most this far from the head (plus
	-- its own bounding radius) before the leash starts ticking.
	MaxHoldDistance = 14,
	-- Time (s) an object may stay outside the leash radius before being dropped.
	-- A short grace period avoids dropping on a momentary physics overshoot.
	LeashGracePeriod = 0.6,
	-- Seconds between leash / validity sweeps.
	LeashInterval = 0.2,

	-- Object limits --------------------------------------------------------
	-- Reject absurdly heavy assemblies (anti-grief). Set to 0 to disable.
	MaxObjectMass = 5000,

	-- Blender pivot correction --------------------------------------------
	-- If a model's pivot sits further than this fraction of its bounding-box
	-- diagonal from the box centre, we drive it by the box centre instead of
	-- the (mis-placed) pivot. This is what keeps custom imports centred.
	PivotCorrectionThreshold = 0.2,

	-- AlignPosition tuning -------------------------------------------------
	-- Higher Responsiveness = snappier follow (0-200).
	PositionResponsiveness = 55,
	-- MaxForce = clamp(mass * gravity * ForceMultiplier, MinForce, MaxForce)
	-- so the *acceleration* applied is consistent across light and heavy props.
	ForceMultiplier = 50,
	MinForce = 30000,
	MaxForce = 8_000_000,
	-- Velocity cap is the key anti-fling guard: the object can never build up
	-- enough speed to tunnel through geometry or yank the player around.
	MaxVelocity = 90,

	-- AlignOrientation tuning ---------------------------------------------
	OrientationResponsiveness = 50,
	-- MaxTorque = clamp(mass * (radius^2 + 1) * TorqueMultiplier, Min, Max),
	-- an inertia-aware approximation so spin feel is consistent across sizes.
	TorqueMultiplier = 4000,
	MinTorque = 40000,
	MaxTorque = 8_000_000,
	MaxAngularVelocity = 35,

	-- Drop -----------------------------------------------------------------
	-- Gentle forward toss applied when an object is deliberately dropped.
	DropImpulseSpeed = 6,

	-- Collision groups (created at runtime) -------------------------------
	CharacterCollisionGroup = "PickupCharacters",
	HeldCollisionGroup = "PickupHeldObjects",

	-- Networking -----------------------------------------------------------
	RemotesFolderName = "PickupSystemRemotes",
}

-- Names for every instance the rig creates, so a hold can be located and torn
-- down deterministically.
local ATTACHMENT_NAME = "PickupHoldAttachment"
local ALIGN_POSITION_NAME = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

----------------------------------------------------------------------
-- Remotes (the server lazily creates them; the client waits for them).
----------------------------------------------------------------------

local function buildRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	assert(folder, "remotes folder")

	local function ensure(name: string)
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	ensure("PickupRequest") -- client -> server : (target: Instance)
	ensure("DropRequest") -- client -> server : ()
	ensure("PickupGranted") -- server -> client : (object, primaryPart, alignPosition, alignOrientation)
	ensure("PickupEnded") -- server -> client : (object)

	return folder
end

local remotesFolder = buildRemotes()
local PickupRequest = remotesFolder:WaitForChild("PickupRequest") :: RemoteEvent
local DropRequest = remotesFolder:WaitForChild("DropRequest") :: RemoteEvent
local PickupGranted = remotesFolder:WaitForChild("PickupGranted") :: RemoteEvent
local PickupEnded = remotesFolder:WaitForChild("PickupEnded") :: RemoteEvent

----------------------------------------------------------------------
-- Geometry helpers (Blender-import friendly).
----------------------------------------------------------------------

-- Every BasePart that makes up an instance (the part itself, or all the parts
-- of a Model).
local function getParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	end
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- The single BasePart the constraints attach to and whose network ownership is
-- transferred. Prefers an explicit PrimaryPart, otherwise the largest part by
-- volume (a robust, stable default for Blender models with no PrimaryPart).
local function getPrimaryPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		if target.PrimaryPart then
			return target.PrimaryPart
		end
		local best: BasePart? = nil
		local bestVolume = -1
		for _, part in getParts(target) do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > bestVolume then
				bestVolume = volume
				best = part
			end
		end
		if best then
			target.PrimaryPart = best
		end
		return best
	end
	return nil
end

-- World-space bounding box (centre CFrame, size). Uses Model:GetBoundingBox()
-- which is computed from the actual visual geometry, so it is immune to a
-- mis-placed Blender pivot.
local function getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- DYNAMIC bounding-box pivot correction (the best Blender fix from the cohort):
-- returns the world-space point the object should be *carried by*. For a model
-- we normally use the bounding-box centre, but if the pivot happens to be close
-- to that centre we trust the pivot (it may be a deliberate handle). When the
-- pivot is far from the visual centre -- the classic Blender import artefact --
-- we snap to the bounding-box centre so the mesh hovers centred, not offset.
local function getVisualCenter(target: Instance): Vector3
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		local pivot = target:GetPivot()
		local boxCFrame, boxSize = target:GetBoundingBox()
		local diagonal = boxSize.Magnitude
		if diagonal > 0 then
			local offsetRatio = (pivot.Position - boxCFrame.Position).Magnitude / diagonal
			if offsetRatio <= Config.PivotCorrectionThreshold then
				return pivot.Position
			end
		end
		return boxCFrame.Position
	end
	return Vector3.zero
end

local function getBoundingRadius(target: Instance): number
	local _, size = getBoundingBox(target)
	return size.Magnitude * 0.5
end

----------------------------------------------------------------------
-- Detection.
----------------------------------------------------------------------

local function isInteractable(instance: Instance): boolean
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return false
	end
	if CollectionService:HasTag(instance, Config.Tag) then
		return true
	end
	return instance:GetAttribute(Config.Attribute) == true
end

-- Walk up from a hit instance to the nearest interactable Model/BasePart.
local function resolveInteractable(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= Workspace do
		if isInteractable(node) then
			return node
		end
		node = node.Parent
	end
	return nil
end

----------------------------------------------------------------------
-- Collision groups (held objects never collide with characters, but still
-- collide with the world and each other).
----------------------------------------------------------------------

local function ensureCollisionGroups()
	-- RegisterCollisionGroup throws if the group already exists (hot reload).
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.CharacterCollisionGroup)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, Config.HeldCollisionGroup)

	PhysicsService:CollisionGroupSetCollidable(Config.HeldCollisionGroup, Config.CharacterCollisionGroup, false)
	PhysicsService:CollisionGroupSetCollidable(Config.HeldCollisionGroup, Config.HeldCollisionGroup, true)
	PhysicsService:CollisionGroupSetCollidable(Config.HeldCollisionGroup, "Default", true)
end

local function assignCharacterGroup(character: Model)
	for _, part in getParts(character) do
		part.CollisionGroup = Config.CharacterCollisionGroup
	end
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Config.CharacterCollisionGroup
		end
	end)
end

-- Move every part of `target` into `group`, returning a snapshot of the
-- previous groups for restoration on drop.
local function applyCollisionGroup(target: Instance, group: string): { [BasePart]: string }
	local snapshot: { [BasePart]: string } = {}
	for _, part in getParts(target) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = group
	end
	return snapshot
end

local function restoreCollisionGroups(snapshot: { [BasePart]: string })
	for part, group in snapshot do
		if part and part.Parent then
			part.CollisionGroup = group
		end
	end
end

----------------------------------------------------------------------
-- Assembly preparation: unanchor + weld loose parts so the whole model is one
-- rigid body, recording everything so the asset is left exactly as found.
----------------------------------------------------------------------

local function unanchor(target: Instance): { [BasePart]: boolean }
	local original: { [BasePart]: boolean } = {}
	for _, part in getParts(target) do
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

local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end

	local connected: { [BasePart]: boolean } = {}
	for _, part in primaryPart:GetConnectedParts(true) do
		connected[part] = true
	end

	for _, part in getParts(target) do
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

----------------------------------------------------------------------
-- The hold rig: AlignPosition + AlignOrientation in OneAttachment mode.
----------------------------------------------------------------------

type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

local function createHoldRig(target: Instance, primaryPart: BasePart): HoldRig
	local mass = math.max(primaryPart.AssemblyMass, 0.1)
	local radius = getBoundingRadius(target)
	local gravity = Workspace.Gravity

	-- The attachment sits at the visual centre (Blender-corrected) but keeps
	-- the primary part's orientation (identity relative rotation). Driving its
	-- position centres the *mesh* on the goal; driving its orientation maps the
	-- goal CFrame straight onto the part's world orientation.
	local centreWorld = getVisualCenter(target)
	local attachment = Instance.new("Attachment")
	attachment.Name = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primaryPart

	local maxForce = math.clamp(mass * gravity * Config.ForceMultiplier, Config.MinForce, Config.MaxForce)
	local maxTorque = math.clamp(mass * (radius * radius + 1) * Config.TorqueMultiplier, Config.MinTorque, Config.MaxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = ALIGN_POSITION_NAME
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	-- Apply force through the centre of mass so a lopsided COM does not spin
	-- the object while it is being dragged (key for irregular imports).
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = Config.MaxVelocity
	alignPosition.Responsiveness = Config.PositionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.MaxAngularVelocity = Config.MaxAngularVelocity
	alignOrientation.Responsiveness = Config.OrientationResponsiveness
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

----------------------------------------------------------------------
-- Network ownership.
----------------------------------------------------------------------

local function giveOwnership(primaryPart: BasePart, player: Player?): boolean
	local ok = pcall(function()
		if not primaryPart:CanSetNetworkOwnership() then
			error("cannot set ownership")
		end
		primaryPart:SetNetworkOwner(player)
	end)
	return ok
end

local function resetOwnership(primaryPart: BasePart)
	pcall(function()
		primaryPart:SetNetworkOwnershipAuto()
	end)
end

----------------------------------------------------------------------
-- Session state.
----------------------------------------------------------------------

type Session = {
	object: Instance,
	primary: BasePart,
	rig: HoldRig,
	welds: { WeldConstraint },
	anchoredSnapshot: { [BasePart]: boolean },
	collisionSnapshot: { [BasePart]: string },
	connections: { RBXScriptConnection },
	boundingRadius: number,
	breachTime: number,
}

local sessions: { [Player]: Session } = {}

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

----------------------------------------------------------------------
-- Drop / teardown.
----------------------------------------------------------------------

local function dropObject(player: Player, applyImpulse: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil

	for _, connection in session.connections do
		connection:Disconnect()
	end

	-- Return ownership before the constraints disappear so the engine settles
	-- the assembly cleanly.
	if session.primary.Parent then
		resetOwnership(session.primary)
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

	restoreCollisionGroups(session.collisionSnapshot)
	restoreAnchors(session.anchoredSnapshot)

	if session.object.Parent then
		session.object:SetAttribute(Config.HeldByAttribute, nil)
	end

	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			session.primary.AssemblyLinearVelocity = head.CFrame.LookVector * Config.DropImpulseSpeed
		end
	end

	if player.Parent then
		PickupEnded:FireClient(player, session.object)
	end
end

----------------------------------------------------------------------
-- Pickup.
----------------------------------------------------------------------

local function onPickupRequest(player: Player, requested: unknown)
	-- One object at a time; the client should drop before grabbing again.
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

	-- Never trust the client's claim; re-derive the interactable on the server.
	local object = resolveInteractable(instance)
	if not object then
		return
	end
	-- Already held by someone (this player or another)?
	if object:GetAttribute(Config.HeldByAttribute) ~= nil then
		return
	end

	local primary = getPrimaryPart(object)
	if not primary or primary.Anchored then
		return
	end

	-- Server-authoritative distance check (robust to off-centre pivots because
	-- it measures to the geometric centre), with latency slack.
	local head = getHead(player)
	if not head then
		return
	end
	local centreWorld = getVisualCenter(object)
	local boundingRadius = getBoundingRadius(object)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > Config.MaxPickupDistance + Config.ServerDistanceTolerance then
		return
	end

	-- Mass sanity (anti-grief / fling protection).
	if Config.MaxObjectMass > 0 and primary.AssemblyMass > Config.MaxObjectMass then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	-- Commit. Order matters: weld first (so AssemblyMass reflects the whole
	-- object), then ownership, then the rig.
	local anchoredSnapshot = unanchor(object)
	local welds = weldAssembly(object, primary)

	if not giveOwnership(primary, player) then
		-- Roll back and bail if ownership could not be transferred.
		for _, weld in welds do
			weld:Destroy()
		end
		restoreAnchors(anchoredSnapshot)
		return
	end

	local collisionSnapshot = applyCollisionGroup(object, Config.HeldCollisionGroup)
	local rig = createHoldRig(object, primary)
	object:SetAttribute(Config.HeldByAttribute, player.UserId)

	local session: Session = {
		object = object,
		primary = primary,
		rig = rig,
		welds = welds,
		anchoredSnapshot = anchoredSnapshot,
		collisionSnapshot = collisionSnapshot,
		connections = {},
		boundingRadius = boundingRadius,
		breachTime = 0,
	}
	sessions[player] = session

	-- Auto-drop if the object (or its primary part) is removed mid-hold.
	table.insert(
		session.connections,
		object.AncestryChanged:Connect(function(_, parent)
			if not parent then
				dropObject(player, false)
			end
		end)
	)
	table.insert(
		session.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then
				dropObject(player, false)
			end
		end)
	)

	-- Hand the owning client the constraints to steer.
	PickupGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
end

----------------------------------------------------------------------
-- Leash loop: the real anti-cheat under client ownership. Drops anything that
-- has drifted too far for too long, or whose object/character is gone.
----------------------------------------------------------------------

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < Config.LeashInterval then
			return
		end
		local elapsed = accumulator
		accumulator = 0

		for player, session in sessions do
			if not session.primary.Parent or not session.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				dropObject(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				dropObject(player, false)
				continue
			end

			local maxDistance = Config.MaxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > Config.LeashGracePeriod then
					dropObject(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

----------------------------------------------------------------------
-- Lifecycle wiring.
----------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	-- A respawn invalidates any current hold.
	dropObject(player, false)
	assignCharacterGroup(character)

	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			dropObject(player, false)
		end)
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

ensureCollisionGroups()

PickupRequest.OnServerEvent:Connect(onPickupRequest)
DropRequest.OnServerEvent:Connect(function(player)
	dropObject(player, true)
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	dropObject(player, false)
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

startLeashLoop()
