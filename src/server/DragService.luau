--!strict
-- Module: server/DragService.luau
-- Ported core of consensus PickupServer with bridged item-type routing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local GeometryUtil = require(ReplicatedStorage.Shared.GeometryUtil)
local ItemRegistry = require(ReplicatedStorage.Shared.ItemRegistry)
local Types = require(ReplicatedStorage.Shared.Types)
local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState = require(script.Parent.PlayerHoldState)

type HoldRig = Types.HoldRig

local ATTACHMENT_NAME = "PickupHoldAttachment"
local ALIGN_POSITION_NAME = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

local DragService = {}

local remotes: {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
}? = nil

local equipService: { forceUnequip: (Player) -> () }? = nil
local rigSessions: { [Player]: Session } = {}
local lastDragRequestAt: { [Player]: number } = {}

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

local function hasAnimatorJoints(target: Instance): boolean
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("Motor6D") or descendant:IsA("AnimationController") then
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
	if hasAnimatorJoints(target) then
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
	local drag = Config.Drag

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

local function destroyRig(rig: HoldRig)
	if rig.alignPosition.Parent then
		rig.alignPosition:Destroy()
	end
	if rig.alignOrientation.Parent then
		rig.alignOrientation:Destroy()
	end
	if rig.attachment.Parent then
		rig.attachment:Destroy()
	end
end

function DragService.drop(player: Player, applyImpulse: boolean, skipHoldClear: boolean?)
	local session = rigSessions[player]
	if not session then
		return
	end
	rigSessions[player] = nil

	for _, connection in session.connections do
		connection:Disconnect()
	end

	if session.primary.Parent then
		PhysicsAuthority.returnOwnership(session.primary)
	end

	destroyRig(session.rig)

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

	if applyImpulse and session.primary.Parent then
		local head = getHead(player)
		if head then
			local impulse = head.CFrame.LookVector * Config.Drag.dropImpulseSpeed * Config.Drag.flingVelocityMultiplier
			session.primary.AssemblyLinearVelocity = clampVelocity(impulse)
		end
	end

	if not skipHoldClear then
		PlayerHoldState.clear(player)
	end

	if remotes and player.Parent then
		remotes.DragEnded:FireClient(player, session.object)
	end
end

function DragService.forceRelease(player: Player, skipHoldClear: boolean?)
	DragService.drop(player, false, skipHoldClear)
end

local function onDragStart(player: Player, requested: unknown)
	local now = os.clock()
	local lastAt = lastDragRequestAt[player] or 0
	if (now - lastAt) * 1000 < Config.Security.dragRequestCooldownMs then
		return
	end
	lastDragRequestAt[player] = now

	if rigSessions[player] then
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
	if object:GetAttribute(Config.HeldByAttribute) ~= nil then
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
	if previous.kind == "Weapon" and equipService then
		equipService.forceUnequip(player, true)
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
	local grabOrientation = primary.CFrame.Rotation
	rig.alignOrientation.CFrame = grabOrientation
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
		grabOrientation = grabOrientation,
	}
	rigSessions[player] = session

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

	if remotes then
		remotes.DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
	end
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

		for player, session in rigSessions do
			if not session.primary.Parent or not session.primary:IsDescendantOf(Workspace) or not isAlive(player) then
				DragService.drop(player, false)
				continue
			end

			local head = getHead(player)
			if not head then
				DragService.drop(player, false)
				continue
			end

			local maxDistance = Config.Drag.maxHoldDistance + session.boundingRadius
			local distance = (session.primary.Position - head.Position).Magnitude
			if distance > maxDistance then
				session.breachTime += elapsed
				if session.breachTime > Config.Drag.leashGracePeriod then
					DragService.drop(player, false)
				end
			else
				session.breachTime = 0
			end
		end
	end)
end

function DragService.configure(options: {
	remotes: typeof(remotes),
	equipService: { forceUnequip: (Player) -> () },
})
	remotes = options.remotes
	equipService = options.equipService
end

function DragService.start()
	if not remotes then
		warn("[DragService] remotes not configured")
		return
	end

	remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remotes.DragEndRequest.OnServerEvent:Connect(function(player)
		DragService.drop(player, true)
	end)

	startLeashLoop()
end

function DragService.onPlayerRemoving(player: Player)
	lastDragRequestAt[player] = nil
	DragService.drop(player, false)
end

function DragService.onCharacterAdded(player: Player)
	DragService.drop(player, false)
end

return DragService
