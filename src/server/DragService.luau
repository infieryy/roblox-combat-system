--!strict
-- Module: server/DragService
-- The ported core of the consensus PickupServer. The server validates a grab
-- request, transfers network ownership of the assembly to the holder, builds an
-- AlignPosition / AlignOrientation rig, then lets the OWNING CLIENT steer the
-- constraint goals locally each frame (zero perceived lag; motion replicates for
-- free). Anti-cheat: finite mass-scaled forces, a velocity cap, and a leash loop
-- that force-drops anything driven too far.
--
-- Bridge changes vs the consensus build:
--   * Props are grabbed by MOUSE (DragStartRequest), never E.
--   * Routed through PlayerHoldState (one item at a time); grabbing a prop while
--     holding a gun triggers EquipService.forceUnequip via the returned prev hold.
--   * Per-remote rate limiting (§14.2) and a capped drop/fling impulse (§14.3).
--   * No-rotation (decision #2): the AlignOrientation goal is set once at grab
--     time and never driven per-frame; inspect-rotate is gated by Config.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

type HoldRig = Types.HoldRig
type Context = { [string]: any }

local DragCfg = Config.Drag

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

local ctx: Context = nil :: any
local sessions: { [Player]: Session } = {}
local lastRequestAt: { [Player]: number } = {}

----------------------------------------------------------------------
-- Helpers (ported).
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

-- Rigidly weld loose parts so the whole model is one assembly. §14.5: skip
-- welding models that already carry animator joints (Motor6D), to avoid
-- fighting a rigged/animated prop.
local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end
	if target:FindFirstChildWhichIsA("Animator", true) or target:FindFirstChildWhichIsA("Motor6D", true) then
		-- Jointed/animated model: leave its existing joints alone.
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

local function createHoldRig(target: Instance, primaryPart: BasePart): HoldRig
	local mass = math.max(primaryPart.AssemblyMass, 0.1)
	local radius = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	local centreWorld = GeometryUtil.getVisualCenter(target)
	local attachment = Instance.new("Attachment")
	attachment.Name = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primaryPart

	local maxForce = math.clamp(mass * gravity * DragCfg.forceMultiplier, DragCfg.minForce, DragCfg.maxForce)
	local maxTorque =
		math.clamp(mass * (radius * radius + 1) * DragCfg.torqueMultiplier, DragCfg.minTorque, DragCfg.maxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = ALIGN_POSITION_NAME
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true -- a lopsided COM cannot induce spin
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = DragCfg.maxVelocity
	alignPosition.Responsiveness = DragCfg.positionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.MaxAngularVelocity = DragCfg.maxAngularVelocity
	alignOrientation.Responsiveness = DragCfg.orientationResponsiveness
	-- Decision #2: orientation goal is fixed at grab time; the client never
	-- drives it per-frame, so the prop holds steady (no rotation).
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

-- Tears down the rig and notifies the client. Does NOT touch PlayerHoldState
-- (so it is safe to call as the counterpart teardown when a gun is equipped).
-- Returns true if a session existed.
local function teardownSession(player: Player, applyImpulse: boolean): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	sessions[player] = nil

	for _, connection in session.connections do
		connection:Disconnect()
	end

	-- Return ownership before the constraints disappear so the assembly settles.
	if session.primary.Parent then
		ctx.physics.returnOwnership(session.primary)
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

	ctx.physics.restoreGroups(session.collisionSnapshot)
	restoreAnchors(session.anchoredSnapshot)

	if session.object.Parent then
		session.object:SetAttribute(Config.HeldByAttribute, nil)
	end

	-- §14.3: a deliberate drop applies a gentle forward toss, but the velocity
	-- is clamped to the same MaxVelocity guard the rig used so a "fling" can
	-- never tunnel geometry or yank the player.
	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			local speed = math.min(DragCfg.dropImpulseSpeed * DragCfg.flingVelocityMultiplier, DragCfg.maxVelocity)
			session.primary.AssemblyLinearVelocity = head.CFrame.LookVector * speed
		end
	end

	if player.Parent then
		ctx.remotes.DragEnded:FireClient(player, session.object)
	end
	return true
end

-- Public: full drop initiated by the player/server lifecycle. Clears hold state.
function DragService.drop(player: Player, applyImpulse: boolean)
	local had = teardownSession(player, applyImpulse)
	if had then
		ctx.holdState.clear(player)
	end
end

-- Public: counterpart teardown called by EquipService when a gun is equipped
-- while a prop is held. Hold state is already being switched by the caller, so
-- this only releases the rig.
function DragService.forceRelease(player: Player)
	teardownSession(player, false)
end

----------------------------------------------------------------------
-- Grab.
----------------------------------------------------------------------

local function onDragStart(player: Player, requested: unknown)
	-- §14.2 rate limit.
	local now = os.clock()
	local last = lastRequestAt[player]
	if last and (now - last) * 1000 < Config.Security.dragRequestCooldownMs then
		return
	end
	lastRequestAt[player] = now

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

	-- Never trust the client; re-derive on the server and require a draggable Prop.
	local object = ItemRegistry.resolve(instance)
	if not object or ItemRegistry.classify(object) ~= "Prop" or not ItemRegistry.isDraggable(object) then
		return
	end
	-- Already held by someone (this player or another)?
	if object:GetAttribute(Config.HeldByAttribute) ~= nil then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then
		return
	end

	-- Server-authoritative distance check to the geometric centre (robust to
	-- off-centre pivots), with latency slack.
	local head = getHead(player)
	if not head then
		return
	end
	local centreWorld = GeometryUtil.getVisualCenter(object)
	local boundingRadius = GeometryUtil.getBoundingRadius(object)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > Config.Security.maxDragStartDistance then
		return
	end

	-- Mass sanity (anti-grief / fling protection).
	if DragCfg.maxObjectMass > 0 and primary.AssemblyMass > DragCfg.maxObjectMass then
		return
	end

	if not player.Character then
		return
	end

	-- One-item rule: claim the prop slot first; if the player was holding a gun,
	-- the previous hold tells us to tear the weapon down.
	local previous = ctx.holdState.setProp(player, object)
	if previous.kind == "Weapon" then
		ctx.equip.forceUnequip(player)
	end

	-- Commit. Order matters: weld first (so AssemblyMass reflects the whole
	-- object), then ownership, then the rig.
	local anchoredSnapshot = unanchor(object)
	local welds = weldAssembly(object, primary)

	if not ctx.physics.giveOwnership(primary, player) then
		for _, weld in welds do
			weld:Destroy()
		end
		restoreAnchors(anchoredSnapshot)
		ctx.holdState.clear(player)
		return
	end

	local collisionSnapshot = ctx.physics.applyHeldGroup(object)
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
				DragService.drop(player, false)
			end
		end)
	)
	table.insert(
		session.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then
				DragService.drop(player, false)
			end
		end)
	)

	-- Hand the owning client the constraints to steer.
	ctx.remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
end

----------------------------------------------------------------------
-- Leash loop (the real anti-cheat under client ownership).
----------------------------------------------------------------------

local function startLeashLoop()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < DragCfg.leashInterval then
			return
		end
		local elapsed = accumulator
		accumulator = 0

		for player, session in sessions do
			if
				not session.primary.Parent
				or not session.primary:IsDescendantOf(Workspace)
				or not isAlive(player)
			then
				DragService.drop(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				DragService.drop(player, false)
				continue
			end

			local maxDistance = DragCfg.maxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > DragCfg.leashGracePeriod then
					DragService.drop(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

function DragService.clearPlayer(player: Player)
	teardownSession(player, false)
	lastRequestAt[player] = nil
end

function DragService.start(context: Context)
	ctx = context

	ctx.remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	ctx.remotes.DragEndRequest.OnServerEvent:Connect(function(player: Player)
		DragService.drop(player, true)
	end)
	Players.PlayerRemoving:Connect(function(player)
		DragService.clearPlayer(player)
	end)

	startLeashLoop()
end

return DragService
