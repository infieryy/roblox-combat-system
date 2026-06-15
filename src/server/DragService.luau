--!strict
-- Module: DragService
-- Authoritative prop-drag handler. Ported from the consensus PickupServer build
-- with the following bridging changes (blueprint §10.5):
--   • Trigger is now DragStartRequest (mouse-down), not PickupRequest (E key).
--   • Classification validated through ItemRegistry ("Prop" only).
--   • PlayerHoldState.setProp enforces the one-item rule; prior weapon triggers
--     the injected unequip callback.
--   • AlignOrientation goal is set ONCE at grab time and not driven per-frame
--     (decision #2: dragged props do not rotate).
--   • Per-remote rate limiting (blueprint §14.2).
--   • Drop impulse velocity clamped to maxVelocity (blueprint §14.3).
--   • forceRelease() exposed for EquipService cross-service teardown.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil   = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))
local ItemRegistry   = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))

-- Late-injected dependencies (set by init.server to avoid circular requires).
local _PlayerHoldState: any = nil
local _PhysicsAuthority: any = nil
local _Remotes: any = nil
local _forceUnequipCallback: ((Player) -> ())? = nil

-- -------------------------------------------------------------------------
-- Session state (one per player, mirrors consensus Session type)
-- -------------------------------------------------------------------------

local ATTACHMENT_NAME     = "PickupHoldAttachment"
local ALIGN_POSITION_NAME = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

type Session = {
	object: Instance,
	primary: BasePart,
	welds: { WeldConstraint },
	anchoredSnapshot: { [BasePart]: boolean },
	collisionSnapshot: { [BasePart]: string },
	connections: { RBXScriptConnection },
	boundingRadius: number,
	breachTime: number,
	-- The three rig instances the client steers.
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

local sessions: { [Player]: Session } = {}
local lastDragRequest: { [Player]: number } = {}

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------

local function getHead(player: Player): BasePart?
	local char = player.Character
	if not char then return nil end
	local head = char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then return head :: BasePart end
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	if root and root:IsA("BasePart") then return root :: BasePart end
	return nil
end

local function isAlive(player: Player): boolean
	local char = player.Character
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function unanchorAll(target: Instance): { [BasePart]: boolean }
	local snap: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(target) do
		snap[part] = part.Anchored
		part.Anchored = false
	end
	return snap
end

local function restoreAnchors(snap: { [BasePart]: boolean })
	for part, anchored in snap do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
end

local function weldAssembly(target: Instance, primary: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then return welds end

	local connected: { [BasePart]: boolean } = {}
	for _, part in primary:GetConnectedParts(true) do
		connected[part] = true
	end

	for _, part in GeometryUtil.getParts(target) do
		if part ~= primary and not connected[part] then
			-- Skip Motor6D-driven parts to avoid breaking animated rigs (§14.5).
			local hasMotor = false
			for _, child in part:GetChildren() do
				if child:IsA("Motor6D") then hasMotor = true; break end
			end
			if not hasMotor then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "PickupWeld"
				weld.Part0 = primary
				weld.Part1 = part
				weld.Parent = primary
				table.insert(welds, weld)
			end
		end
	end
	return welds
end

local function createHoldRig(target: Instance, primary: BasePart): (Attachment, AlignPosition, AlignOrientation)
	local mass    = math.max(primary.AssemblyMass, 0.1)
	local radius  = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	-- Place the attachment at the visual centre (Blender-pivot-corrected) but
	-- keep the primary part's orientation so goal CFrames map cleanly.
	local centreWorld = GeometryUtil.getVisualCenter(target)
	local att = Instance.new("Attachment")
	att.Name = ATTACHMENT_NAME
	att.CFrame = CFrame.new(primary.CFrame:PointToObjectSpace(centreWorld))
	att.Parent = primary

	local maxForce = math.clamp(
		mass * gravity * Config.Drag.forceMultiplier,
		Config.Drag.minForce, Config.Drag.maxForce
	)
	local maxTorque = math.clamp(
		mass * (radius * radius + 1) * Config.Drag.torqueMultiplier,
		Config.Drag.minTorque, Config.Drag.maxTorque
	)

	local ap = Instance.new("AlignPosition")
	ap.Name = ALIGN_POSITION_NAME
	ap.Mode = Enum.PositionAlignmentMode.OneAttachment
	ap.Attachment0 = att
	ap.ApplyAtCenterOfMass = true   -- lopsided COM won't spin the object mid-drag
	ap.RigidityEnabled = false
	ap.ReactionForceEnabled = false
	ap.MaxForce = maxForce
	ap.MaxVelocity = Config.Drag.maxVelocity
	ap.Responsiveness = Config.Drag.positionResponsiveness
	ap.Position = centreWorld
	ap.Parent = primary

	local ao = Instance.new("AlignOrientation")
	ao.Name = ALIGN_ORIENTATION_NAME
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.ReactionTorqueEnabled = false
	ao.MaxTorque = maxTorque
	ao.MaxAngularVelocity = Config.Drag.maxAngularVelocity
	ao.Responsiveness = Config.Drag.orientationResponsiveness
	-- Decision #2: orientation goal fixed at grab-time; client does NOT drive it
	-- per-frame (inspect-rotate path gated by Config.Drag.enableInspect).
	ao.CFrame = primary.CFrame.Rotation
	ao.Parent = primary

	return att, ap, ao
end

-- -------------------------------------------------------------------------
-- Drop / teardown
-- -------------------------------------------------------------------------

local function _drop(player: Player, applyImpulse: boolean)
	local s = sessions[player]
	if not s then return end
	sessions[player] = nil

	for _, c in s.connections do c:Disconnect() end

	if s.primary.Parent then
		_PhysicsAuthority.returnOwnership(s.primary)
	end

	if s.alignPosition.Parent then s.alignPosition:Destroy() end
	if s.alignOrientation.Parent then s.alignOrientation:Destroy() end
	if s.attachment.Parent then s.attachment:Destroy() end

	for _, weld in s.welds do
		if weld.Parent then weld:Destroy() end
	end

	_PhysicsAuthority.restoreGroups(s.collisionSnapshot)
	restoreAnchors(s.anchoredSnapshot)

	if s.object.Parent then
		s.object:SetAttribute(Config.Detection.heldByAttribute, nil)
	end

	if applyImpulse and s.primary.Parent then
		local head = getHead(player)
		if head then
			-- Blueprint §14.3: clamp drop velocity to maxVelocity (consensus had no cap).
			local speed = math.min(Config.Drag.dropImpulseSpeed * Config.Drag.flingVelocityMultiplier, Config.Drag.maxVelocity)
			s.primary.AssemblyLinearVelocity = head.CFrame.LookVector * speed
		end
	end

	_PlayerHoldState.clear(player)

	if player.Parent then
		_Remotes.DragEnded:FireClient(player, s.object)
	end
end

-- -------------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------------

local DragService = {}

-- forceRelease is called by EquipService when equipping a weapon while the
-- player is dragging. It drops without impulse.
function DragService.forceRelease(player: Player)
	_drop(player, false)
end

function DragService.setForceUnequipCallback(callback: (Player) -> ())
	_forceUnequipCallback = callback
end

-- -------------------------------------------------------------------------
-- Pickup handler
-- -------------------------------------------------------------------------

local function onDragStart(player: Player, requested: unknown)
	-- Rate limit (blueprint §14.2 / §10.5).
	local now = os.clock()
	local lastTime = lastDragRequest[player] or 0
	if now - lastTime < Config.Security.dragRequestCooldown then return end
	lastDragRequest[player] = now

	-- One prop at a time.
	if sessions[player] then return end

	if typeof(requested) ~= "Instance" then return end
	local instance = requested :: Instance

	if not instance:IsDescendantOf(Workspace) then return end
	if not isAlive(player) then return end

	-- Server re-derives the interactable and validates classification.
	local object = instance
	-- Walk up to the tagged root (mirrors resolveInteractable from consensus).
	local node: Instance? = instance
	while node and node ~= Workspace do
		if ItemRegistry.classify(node :: Instance) == "Prop" then
			object = node :: Instance
			break
		end
		node = (node :: Instance).Parent
	end
	if ItemRegistry.classify(object) ~= "Prop" then return end
	if not ItemRegistry.isDraggable(object) then return end

	-- Already held by someone?
	if object:GetAttribute(Config.Detection.heldByAttribute) ~= nil then return end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then return end

	local head = getHead(player)
	if not head then return end

	local centreWorld = GeometryUtil.getVisualCenter(object)
	local boundingRadius = GeometryUtil.getBoundingRadius(object)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	if distance > Config.Security.maxDragStartDistance then return end

	if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then return end

	-- One-item rule: if player is holding a weapon, unequip it first.
	local prev = _PlayerHoldState.get(player)
	if prev.kind == "Weapon" then
		if _forceUnequipCallback then
			_forceUnequipCallback(player)
		end
	end

	-- Commit (order matters: weld → ownership → rig).
	local anchoredSnapshot = unanchorAll(object)
	local welds = weldAssembly(object, primary)

	if not _PhysicsAuthority.giveOwnership(primary, player) then
		for _, w in welds do w:Destroy() end
		restoreAnchors(anchoredSnapshot)
		return
	end

	local collisionSnapshot = _PhysicsAuthority.applyHeldGroup(object)
	local att, ap, ao = createHoldRig(object, primary)
	object:SetAttribute(Config.Detection.heldByAttribute, player.UserId)

	_PlayerHoldState.setProp(player, object)

	local session: Session = {
		object = object,
		primary = primary,
		attachment = att,
		alignPosition = ap,
		alignOrientation = ao,
		welds = welds,
		anchoredSnapshot = anchoredSnapshot,
		collisionSnapshot = collisionSnapshot,
		connections = {},
		boundingRadius = boundingRadius,
		breachTime = 0,
	}
	sessions[player] = session

	-- Auto-drop if the prop is removed while held.
	table.insert(session.connections,
		object.AncestryChanged:Connect(function(_, parent)
			if not parent then _drop(player, false) end
		end)
	)
	table.insert(session.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then _drop(player, false) end
		end)
	)

	-- Hand the owning client the constraint refs to steer locally.
	_Remotes.DragGranted:FireClient(player, object, primary, ap, ao)
end

-- -------------------------------------------------------------------------
-- Leash loop (anti-cheat — drops parts driven too far by an exploiter)
-- -------------------------------------------------------------------------

local function startLeashLoop()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < Config.Drag.leashInterval then return end
		local elapsed = acc
		acc = 0

		for player, s in sessions do
			if not s.primary.Parent or not s.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				_drop(player, false)
				continue
			end

			local head = getHead(player)
			if not head then _drop(player, false); continue end

			local maxDist = Config.Drag.maxHoldDistance + s.boundingRadius
			local dist = (s.primary.Position - head.Position).Magnitude
			if dist > maxDist then
				s.breachTime += elapsed
				if s.breachTime > Config.Drag.leashGracePeriod then
					_drop(player, false)
				end
			else
				s.breachTime = 0
			end
		end
	end)
end

-- -------------------------------------------------------------------------
-- start() — called by init.server after all deps are wired
-- -------------------------------------------------------------------------

function DragService.start(deps: {
	Remotes: any,
	PlayerHoldState: any,
	PhysicsAuthority: any,
})
	_Remotes = deps.Remotes
	_PlayerHoldState = deps.PlayerHoldState
	_PhysicsAuthority = deps.PhysicsAuthority

	_Remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	_Remotes.DragEndRequest.OnServerEvent:Connect(function(player: Player)
		_drop(player, true)
	end)

	startLeashLoop()
end

-- -------------------------------------------------------------------------
-- Lifecycle hooks (called by init.server)
-- -------------------------------------------------------------------------

function DragService.onCharacterAdded(player: Player)
	-- Respawn invalidates the current drag.
	_drop(player, false)
end

function DragService.onPlayerRemoving(player: Player)
	_drop(player, false)
	lastDragRequest[player] = nil
end

return DragService
