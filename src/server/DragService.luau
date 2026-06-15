--!strict
-- Module: Server-authoritative drag service ported from consensus build.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local GeometryUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GeometryUtil"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemRegistry"))
local SharedTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))
type HoldRig = SharedTypes.HoldRig

local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState = require(script.Parent.PlayerHoldState)
type RemotesModule = typeof(require(script.Parent.Remotes))
type RemoteBundle = RemotesModule.RemoteBundle

type EquipServiceContract = {
	forceUnequip: (player: Player) -> (),
}

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

local remotes: RemoteBundle? = nil
local equipService: EquipServiceContract? = nil

local sessions: { [Player]: Session } = {}
local lastDragRequestAt: { [Player]: number } = {}
local leashStarted = false

local ATTACHMENT_NAME = "PickupHoldAttachment"
local ALIGN_POSITION_NAME = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

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

local function resolveProp(hit: Instance?): Instance?
	local node = hit
	while node and node ~= Workspace do
		if ItemRegistry.classify(node) == "Prop" then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function unanchor(target: Instance): { [BasePart]: boolean }
	local snapshot: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshot[part] = part.Anchored
		part.Anchored = false
	end
	return snapshot
end

local function restoreAnchors(snapshot: { [BasePart]: boolean })
	for part, anchored in snapshot do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
end

local function hasMotorJoints(target: Instance): boolean
	if target:IsA("Model") then
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("Motor6D") then
				return true
			end
		end
	end
	return false
end

local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end

	-- Motor6D rigs are usually animated/jointed assets and should not be rigidly welded.
	if hasMotorJoints(target) then
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

	local maxForce = math.clamp(
		mass * gravity * Config.Drag.forceMultiplier,
		Config.Drag.minForce,
		Config.Drag.maxForce
	)
	local maxTorque = math.clamp(
		mass * (radius * radius + 1) * Config.Drag.torqueMultiplier,
		Config.Drag.minTorque,
		Config.Drag.maxTorque
	)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = ALIGN_POSITION_NAME
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = Config.Drag.maxVelocity
	alignPosition.Responsiveness = Config.Drag.positionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.MaxAngularVelocity = Config.Drag.maxAngularVelocity
	alignOrientation.Responsiveness = Config.Drag.orientationResponsiveness
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local previous = lastDragRequestAt[player]
	lastDragRequestAt[player] = now
	if not previous then
		return false
	end
	local dtMs = (now - previous) * 1000
	return dtMs < Config.Security.dragRequestCooldownMs
end

local function cleanupSessionObjects(session: Session)
	for _, connection in session.connections do
		connection:Disconnect()
	end

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
		session.object:SetAttribute(Config.Drag.heldByAttribute, nil)
	end
end

local function drop(player: Player, applyImpulse: boolean, clearHoldState: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil

	cleanupSessionObjects(session)

	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			local speed = Config.Drag.dropImpulseSpeed * Config.Drag.flingVelocityMultiplier
			speed = math.min(speed, Config.Drag.maxVelocity)
			session.primary.AssemblyLinearVelocity = head.CFrame.LookVector * speed
		end
	end

	if clearHoldState then
		local current = PlayerHoldState.get(player)
		if current.kind == "Prop" then
			PlayerHoldState.clear(player)
		end
	end

	if remotes and player.Parent then
		remotes.DragEnded:FireClient(player, session.object)
	end
end

local function onDragStart(player: Player, requested: unknown)
	if isRateLimited(player) then
		return
	end

	if typeof(requested) ~= "Instance" then
		return
	end
	local requestedInstance = requested :: Instance
	if not requestedInstance:IsDescendantOf(Workspace) then
		return
	end
	if not isAlive(player) then
		return
	end

	local object = resolveProp(requestedInstance)
	if not object then
		return
	end
	if object:GetAttribute(Config.Drag.heldByAttribute) ~= nil then
		return
	end
	if not ItemRegistry.isDraggable(object) then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then
		return
	end

	if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then
		return
	end

	local head = getHead(player)
	if not head then
		return
	end

	local centreWorld = GeometryUtil.getVisualCenter(object)
	local boundingRadius = GeometryUtil.getBoundingRadius(object)
	local distance = (centreWorld - head.Position).Magnitude - boundingRadius
	local maxDistance = math.min(
		Config.Drag.maxPickupDistance + Config.Drag.serverDistanceTolerance,
		Config.Security.maxDragStartDistance
	)
	if distance > maxDistance then
		return
	end

	-- If this player already had a prop session, release its rig first.
	if sessions[player] then
		drop(player, false, false)
	end

	local previous = PlayerHoldState.setProp(player, object)
	if previous.kind == "Weapon" and equipService then
		equipService.forceUnequip(player)
	end

	local anchoredSnapshot = unanchor(object)
	local welds = weldAssembly(object, primary)

	if not PhysicsAuthority.giveOwnership(primary, player) then
		for _, weld in welds do
			if weld.Parent then
				weld:Destroy()
			end
		end
		restoreAnchors(anchoredSnapshot)
		PlayerHoldState.clear(player)
		return
	end

	local collisionSnapshot = PhysicsAuthority.applyHeldGroup(object)
	local rig = createHoldRig(object, primary)

	object:SetAttribute(Config.Drag.heldByAttribute, player.UserId)

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

	table.insert(session.connections, object.AncestryChanged:Connect(function(_, parent: Instance?)
		if not parent then
			drop(player, false, true)
		end
	end))

	table.insert(session.connections, primary.AncestryChanged:Connect(function(_, parent: Instance?)
		if not parent then
			drop(player, false, true)
		end
	end))

	if remotes then
		remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
	end
end

local function onDragEnd(player: Player)
	if isRateLimited(player) then
		return
	end
	drop(player, true, true)
end

local function startLeashLoop()
	if leashStarted then
		return
	end
	leashStarted = true

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < Config.Drag.leashInterval then
			return
		end
		local elapsed = accumulator
		accumulator = 0

		for player, session in sessions do
			if not session.primary.Parent or not session.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				drop(player, false, true)
				continue
			end

			local head = getHead(player)
			if not head then
				drop(player, false, true)
				continue
			end

			local maxDistance = Config.Drag.maxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > Config.Drag.leashGracePeriod then
					drop(player, false, true)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

function DragService.start(remoteBundle: RemoteBundle)
	remotes = remoteBundle
	remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remotes.DragEndRequest.OnServerEvent:Connect(onDragEnd)
	startLeashLoop()
end

function DragService.setEquipService(service: EquipServiceContract)
	equipService = service
end

function DragService.forceRelease(player: Player)
	drop(player, false, true)
end

function DragService.cleanupPlayer(player: Player)
	drop(player, false, true)
	lastDragRequestAt[player] = nil
end

return DragService
