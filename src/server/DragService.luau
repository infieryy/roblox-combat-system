--!strict
-- Module: DragService
-- Ported authoritative drag physics from consensus PickupServer.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))
local Types = require(Shared:WaitForChild("Types"))

local Remotes = require(script.Parent.Remotes)
local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type HoldRig = Types.HoldRig

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
	grabOrientation: CFrame,
}

local DragService = {}

local remotes: Remotes.RemotesTable? = nil
local sessions: { [Player]: Session } = {}
local lastRequestAt: { [Player]: number } = {}
local equipForceUnequip: ((player: Player) -> ())? = nil

function DragService.setEquipForceUnequip(callback: (player: Player) -> ())
	equipForceUnequip = callback
end

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

local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not target:IsA("Model") then
		return welds
	end

	if GeometryUtil.hasAnimatorJoints(target) then
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
	local drag = Config.Drag
	local mass = math.max(primaryPart.AssemblyMass, 0.1)
	local radius = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	local centreWorld = GeometryUtil.getVisualCenter(target)
	local attachment = Instance.new("Attachment")
	attachment.Name = ATTACHMENT_NAME
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centreWorld))
	attachment.Parent = primaryPart

	local maxForce = math.clamp(mass * gravity * drag.forceMultiplier, drag.minForce, drag.maxForce)
	local maxTorque = math.clamp(mass * (radius * radius + 1) * drag.torqueMultiplier, drag.minTorque, drag.maxTorque)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = ALIGN_POSITION_NAME
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = drag.maxVelocity
	alignPosition.Responsiveness = drag.positionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = ALIGN_ORIENTATION_NAME
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.MaxAngularVelocity = drag.maxAngularVelocity
	alignOrientation.Responsiveness = drag.orientationResponsiveness
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

local function clampVelocity(velocity: Vector3): Vector3
	local maxSpeed = Config.Drag.maxVelocity
	local magnitude = velocity.Magnitude
	if magnitude <= maxSpeed then
		return velocity
	end
	return velocity.Unit * maxSpeed
end

local function teardownSession(player: Player, applyImpulse: boolean)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil

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
		session.object:SetAttribute(Config.Attributes.heldBy, nil)
	end

	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			local impulse = head.CFrame.LookVector * Config.Drag.dropImpulseSpeed * Config.Drag.flingVelocityMultiplier
			session.primary.AssemblyLinearVelocity = clampVelocity(impulse)
		end
	end

	PlayerHoldState.clear(player)

	if player.Parent and remotes then
		remotes.DragEnded:FireClient(player, session.object)
	end
end

function DragService.forceRelease(player: Player)
	teardownSession(player, false)
end

local function canRequest(player: Player): boolean
	local now = os.clock()
	local last = lastRequestAt[player] or 0
	if (now - last) * 1000 < Config.Security.dragRequestCooldownMs then
		return false
	end
	lastRequestAt[player] = now
	return true
end

local function onDragStart(player: Player, requested: unknown)
	if not canRequest(player) then
		return
	end
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

	local object = ItemRegistry.resolveFromHit(instance, Workspace)
	if not object or ItemRegistry.classify(object) ~= "Prop" or not ItemRegistry.isDraggable(object) then
		return
	end

	if object:GetAttribute(Config.Attributes.heldBy) ~= nil then
		return
	end

	local primary = GeometryUtil.getPrimaryPart(object)
	if not primary or primary.Anchored then
		return
	end

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

	if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then
		return
	end

	local previous = PlayerHoldState.setProp(player, object)
	if previous.kind == "Weapon" and equipForceUnequip then
		equipForceUnequip(player)
	end

	local anchoredSnapshot = unanchor(object)
	local welds = weldAssembly(object, primary)

	if not PhysicsAuthority.giveOwnership(primary, player) then
		for _, weld in welds do
			weld:Destroy()
		end
		restoreAnchors(anchoredSnapshot)
		PlayerHoldState.clear(player)
		return
	end

	local collisionSnapshot = PhysicsAuthority.applyHeldGroup(object)
	local rig = createHoldRig(object, primary)
	object:SetAttribute(Config.Attributes.heldBy, player.UserId)

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
		grabOrientation = primary.CFrame.Rotation,
	}
	sessions[player] = session

	table.insert(
		session.connections,
		object.AncestryChanged:Connect(function(_, parent)
			if not parent then
				teardownSession(player, false)
			end
		end)
	)
	table.insert(
		session.connections,
		primary.AncestryChanged:Connect(function(_, parent)
			if not parent then
				teardownSession(player, false)
			end
		end)
	)

	if remotes then
		remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
	end
end

local function onDragEnd(player: Player)
	teardownSession(player, true)
end

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
			if not session.primary.Parent or not session.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				teardownSession(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				teardownSession(player, false)
				continue
			end

			local maxDistance = Config.Drag.maxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > Config.Drag.leashGracePeriod then
					teardownSession(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

function DragService.onPlayerRemoving(player: Player)
	teardownSession(player, false)
	lastRequestAt[player] = nil
end

function DragService.onCharacterAdded(player: Player)
	teardownSession(player, false)
end

function DragService.start(remoteTable: Remotes.RemotesTable)
	remotes = remoteTable
	remoteTable.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remoteTable.DragEndRequest.OnServerEvent:Connect(onDragEnd)
	startLeashLoop()
end

return DragService
