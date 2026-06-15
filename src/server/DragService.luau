--!strict
-- Module: server/DragService
-- The PORTED core of the consensus PickupServer (BLUEPRINT.md §6, §10.5): the
-- AlignPosition + AlignOrientation hold rig, network-ownership transfer,
-- welding/unanchoring, collision isolation and the leash anti-cheat loop.
--
-- Bridged changes vs. the consensus build:
--   * Trigger is now a MOUSE-GRAB request (no E); E is reserved for weapons.
--   * Props do not rotate (decision #2): the orientation goal is fixed at the
--     grab orientation and never driven per-frame; inspect stays gated off.
--   * §14.2 per-remote rate limiting.
--   * §14.3 fling is the object's retained velocity, clamped to maxVelocity
--     (the consensus overrode it with a forward toss, killing the fling).
--   * §14.5 weld safety: animated/jointed models are not rigid-welded.
--   * One-item rule routed through PlayerHoldState (auto-unequip a held gun).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))
local Types = require(Shared:WaitForChild("Types"))

type HoldRig = Types.HoldRig

local DRAG = Config.Drag
local ATTR = Config.Attributes

local ATTACHMENT_NAME = "PickupHoldAttachment"
local ALIGN_POSITION_NAME = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

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

local DragService = {}

local remotes: any = nil
local holdState: any = nil
local physics: any = nil
local equipService: any = nil

local sessions: { [Player]: Session } = {}
local lastDragRequest: { [Player]: number } = {}

----------------------------------------------------------------------
-- Lifecycle helpers (ported).
----------------------------------------------------------------------

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
-- Assembly preparation (ported, with §14.5 weld safety).
----------------------------------------------------------------------

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

-- §14.5: a Motor6D-rigged / animated model must not be rigidly welded or it can
-- behave oddly. Detect animator joints and skip welding for those.
local function isAnimatedAssembly(target: Instance): boolean
	if target:FindFirstChildOfClass("Humanoid") then
		return true
	end
	if target:FindFirstChildWhichIsA("AnimationController", true) then
		return true
	end
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("Motor6D") or descendant:IsA("Humanoid") or descendant:IsA("Animator") then
			return true
		end
	end
	return false
end

local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end
	if isAnimatedAssembly(target) then
		warn("[DragService] Skipping weld for animated/jointed model '" .. target.Name .. "'.")
		return welds
	end

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

----------------------------------------------------------------------
-- Hold rig (ported). Orientation goal set once; not driven per-frame (decision #2).
----------------------------------------------------------------------

local function createHoldRig(target: Instance, primaryPart: BasePart): HoldRig
	local mass = math.max(primaryPart.AssemblyMass, 0.1)
	local radius = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	local centreWorld = GeometryUtil.getVisualCenter(target)
	local attachment = Instance.new("Attachment")
	attachment.Name = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primaryPart

	local maxForce = math.clamp(mass * gravity * DRAG.forceMultiplier, DRAG.minForce, DRAG.maxForce)
	local maxTorque = math.clamp(mass * (radius * radius + 1) * DRAG.torqueMultiplier, DRAG.minTorque, DRAG.maxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = ALIGN_POSITION_NAME
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = DRAG.maxVelocity
	alignPosition.Responsiveness = DRAG.positionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.MaxAngularVelocity = DRAG.maxAngularVelocity
	alignOrientation.Responsiveness = DRAG.orientationResponsiveness
	-- Fixed at the grab orientation; props do not rotate (decision #2).
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

----------------------------------------------------------------------
-- Teardown.
----------------------------------------------------------------------

-- Physically tears the rig down and restores the asset to how it was found.
-- Does NOT touch PlayerHoldState (per the cross-service teardown contract the
-- caller owns hold-state changes). Always notifies the client via DragEnded.
local function teardownSession(player: Player, applyFling: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil

	for _, connection in session.connections do
		connection:Disconnect()
	end

	-- Return ownership before the constraints disappear so the assembly settles.
	if session.primary.Parent then
		physics.returnOwnership(session.primary)
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

	physics.restoreGroups(session.collisionSnapshot)
	restoreAnchors(session.anchoredSnapshot)

	if session.object.Parent then
		session.object:SetAttribute(ATTR.heldBy, nil)
	end

	-- §14.3: fling = retained velocity, scaled then clamped to maxVelocity.
	-- (Only a near-stationary deliberate drop gets the gentle forward toss.)
	if applyFling and session.primary.Parent then
		local velocity = session.primary.AssemblyLinearVelocity * DRAG.flingVelocityMultiplier
		if velocity.Magnitude < 0.1 then
			local head = getHead(player)
			if head then
				velocity = head.CFrame.LookVector * DRAG.dropImpulseSpeed
			end
		end
		if velocity.Magnitude > DRAG.maxVelocity then
			velocity = velocity.Unit * DRAG.maxVelocity
		end
		session.primary.AssemblyLinearVelocity = velocity
	end

	if player.Parent then
		remotes.DragEnded:FireClient(player, session.object)
	end
end

-- Full drop: physical teardown + authoritative hold-state clear.
local function fullDrop(player: Player, applyFling: boolean)
	if not sessions[player] then
		return
	end
	teardownSession(player, applyFling)
	holdState.clear(player)
end

-- Public: tear down the rig WITHOUT clearing hold state. Called by EquipService
-- when a weapon equip supersedes a held prop (the caller already set the new
-- hold state to Weapon).
function DragService.forceRelease(player: Player)
	teardownSession(player, false)
end

----------------------------------------------------------------------
-- Drag start.
----------------------------------------------------------------------

local function onDragStart(player: Player, requested: unknown)
	-- One drag at a time.
	if sessions[player] then
		return
	end

	-- §14.2 rate limit.
	local now = os.clock()
	local last = lastDragRequest[player]
	if last and (now - last) * 1000 < Config.Security.dragRequestCooldownMs then
		return
	end
	lastDragRequest[player] = now

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

	-- Never trust the client; re-derive and classify on the server.
	local object = ItemRegistry.resolve(instance)
	if not object or not ItemRegistry.isDraggable(object) then
		return
	end
	-- Already held by someone?
	if object:GetAttribute(ATTR.heldBy) ~= nil then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then
		return
	end

	-- Server-authoritative distance check (to the geometric centre, with slack).
	local head = getHead(player)
	if not head then
		return
	end
	local centreWorld = GeometryUtil.getVisualCenter(object)
	local boundingRadius = GeometryUtil.getBoundingRadius(object)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > DRAG.maxPickupDistance + DRAG.serverDistanceTolerance then
		return
	end

	-- Mass sanity (anti-grief / fling protection).
	if DRAG.maxObjectMass > 0 and primary.AssemblyMass > DRAG.maxObjectMass then
		return
	end

	-- Commit physics first so a failure leaves hold state untouched. Order:
	-- weld (so AssemblyMass reflects the whole object), then ownership, then rig.
	local anchoredSnapshot = unanchor(object)
	local welds = weldAssembly(object, primary)

	if not physics.giveOwnership(primary, player) then
		for _, weld in welds do
			weld:Destroy()
		end
		restoreAnchors(anchoredSnapshot)
		return
	end

	local collisionSnapshot = physics.applyHeldGroup(object)
	local rig = createHoldRig(object, primary)
	object:SetAttribute(ATTR.heldBy, player.UserId)

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

	-- Authoritative hold state + one-item swap: a prior weapon is force-unequipped.
	local previous = holdState.setProp(player, object)
	if previous.kind == "Weapon" and equipService then
		equipService.forceUnequip(player)
	end

	-- Auto-drop if the object (or its primary part) is removed mid-hold.
	table.insert(
		session.connections,
		object.AncestryChanged:Connect(function(_, parent)
			if not parent then
				fullDrop(player, false)
			end
		end)
	)
	table.insert(
		session.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then
				fullDrop(player, false)
			end
		end)
	)

	-- Hand the owning client the constraints to steer.
	remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
end

----------------------------------------------------------------------
-- Leash loop (ported): the real anti-cheat under client ownership.
----------------------------------------------------------------------

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < DRAG.leashInterval then
			return
		end
		local elapsed = accumulator
		accumulator = 0

		for player, session in sessions do
			if not session.primary.Parent or not session.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				fullDrop(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				fullDrop(player, false)
				continue
			end

			local maxDistance = DRAG.maxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > DRAG.leashGracePeriod then
					fullDrop(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

----------------------------------------------------------------------
-- Public lifecycle hooks (called by init.server).
----------------------------------------------------------------------

-- Force-drop on death/respawn/disconnect.
function DragService.dropPlayer(player: Player)
	fullDrop(player, false)
end

function DragService.cleanupPlayer(player: Player)
	fullDrop(player, false)
	lastDragRequest[player] = nil
end

function DragService.init(deps: { remotes: any, holdState: any, physics: any, equipService: any })
	remotes = deps.remotes
	holdState = deps.holdState
	physics = deps.physics
	equipService = deps.equipService

	remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remotes.DragEndRequest.OnServerEvent:Connect(function(player: Player)
		fullDrop(player, true)
	end)

	startLeashLoop()
end

return DragService
