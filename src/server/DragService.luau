--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local PlayerHoldState = require(script.Parent:WaitForChild("PlayerHoldState"))

type Session = {
	player: Player,
	prop: Instance,
	primary: BasePart,
	rig: any,
	welds: { WeldConstraint },
	originalAnchored: { [BasePart]: boolean },
	originalCollision: { [BasePart]: string },
	breachTime: number,
	boundingRadius: number,
	connections: { RBXScriptConnection },
}

local DragService = {}

local remotes: any = nil
local equipService: any = nil

local sessionsByPlayer: { [Player]: Session } = {}
local playerByProp: { [Instance]: Player } = {}

local function getHead(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
end

local function releaseSession(player: Player, reason: string, applyImpulse: boolean)
	local session = sessionsByPlayer[player]
	if not session then
		return
	end
	sessionsByPlayer[player] = nil
	playerByProp[session.prop] = nil

	disconnectAll(session.connections)

	GeometryUtil.destroyHoldRig(session.rig)
	for _, weld in session.welds do
		weld:Destroy()
	end
	GeometryUtil.restoreCollisionGroups(session.originalCollision)
	GeometryUtil.restoreAnchors(session.originalAnchored)

	if session.primary.Parent then
		pcall(function()
			session.primary:SetNetworkOwnershipAuto()
		end)

		if applyImpulse then
			local look = Vector3.new()
			local character = player.Character
			if character then
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					look = root.CFrame.LookVector
				end
			end
			local speed = math.min(Config.Drag.dropImpulseSpeed, Config.Drag.maxVelocity)
			session.primary.AssemblyLinearVelocity = look * speed * Config.Drag.flingVelocityMultiplier
		end
	end

	if session.prop.Parent then
		session.prop:SetAttribute(Config.Interaction.heldByAttribute, nil)
	end

	local hold = PlayerHoldState.get(player)
	if hold.kind == "Prop" then
		PlayerHoldState.clear(player)
	end

	remotes.DragEnded:FireClient(player, session.prop, reason)
end

local function validateDragStart(player: Player, propInstance: Instance): (Instance?, BasePart?)
	if sessionsByPlayer[player] then
		return nil, nil
	end

	local resolved = ItemRegistry.resolveItemRoot(propInstance)
	if not resolved then
		return nil, nil
	end
	if ItemRegistry.classify(resolved) ~= "Prop" then
		return nil, nil
	end
	if not ItemRegistry.isDraggable(resolved) then
		return nil, nil
	end
	if playerByProp[resolved] then
		return nil, nil
	end
	if resolved:GetAttribute(Config.Interaction.heldByAttribute) ~= nil then
		return nil, nil
	end

	local primary = GeometryUtil.getPrimaryPart(resolved)
	if not primary then
		return nil, nil
	end

	local head = getHead(player)
	if not head then
		return nil, nil
	end

	local boxCF = GeometryUtil.getBoundingBox(resolved)
	local distance = (boxCF.Position - head.Position).Magnitude
	local maxDistance = Config.Validation.maxDragStartDistance * Config.Drag.serverDistanceTolerance
	if distance > maxDistance then
		return nil, nil
	end

	local mass = GeometryUtil.getMass(resolved)
	if mass > Config.Drag.maxHoldMass then
		return nil, nil
	end

	return resolved, primary
end

local function onDragStart(player: Player, requested: any)
	if typeof(requested) ~= "Instance" then
		return
	end

	local prop, primary = validateDragStart(player, requested)
	if not prop or not primary then
		return
	end

	prop:SetAttribute(Config.Interaction.heldByAttribute, player.UserId)
	local originalAnchored = GeometryUtil.unanchor(prop)
	local welds = GeometryUtil.weldAssembly(prop, primary)
	local originalCollision = GeometryUtil.setCollisionGroup(prop, Config.CollisionGroups.heldObject)

	local ownershipOk = pcall(function()
		primary:SetNetworkOwner(player)
	end)
	if not ownershipOk then
		GeometryUtil.restoreCollisionGroups(originalCollision)
		for _, weld in welds do
			weld:Destroy()
		end
		GeometryUtil.restoreAnchors(originalAnchored)
		prop:SetAttribute(Config.Interaction.heldByAttribute, nil)
		return
	end

	local rig = GeometryUtil.createHoldRig(prop, primary, {
		positionResponsiveness = Config.Drag.positionResponsiveness,
		orientationResponsiveness = Config.Drag.orientationResponsiveness,
		maxVelocity = Config.Drag.maxVelocity,
		maxAngularVelocity = Config.Drag.maxAngularVelocity,
		positionForceMultiplier = Config.Drag.positionForceMultiplier,
		orientationTorqueMultiplier = Config.Drag.orientationTorqueMultiplier,
	})

	local previous = PlayerHoldState.setProp(player, prop)
	if previous.kind == "Weapon" and equipService then
		equipService.forceUnequip(player, "drag_started", true)
	end

	local session: Session = {
		player = player,
		prop = prop,
		primary = primary,
		rig = rig,
		welds = welds,
		originalAnchored = originalAnchored,
		originalCollision = originalCollision,
		breachTime = 0,
		boundingRadius = GeometryUtil.getBoundingRadius(prop),
		connections = {},
	}
	sessionsByPlayer[player] = session
	playerByProp[prop] = player

	table.insert(session.connections, prop.AncestryChanged:Connect(function(_, parent)
		if not parent then
			releaseSession(player, "prop_removed", false)
		end
	end))
	table.insert(session.connections, primary.AncestryChanged:Connect(function(_, parent)
		if not parent then
			releaseSession(player, "primary_removed", false)
		end
	end))

	remotes.DragGranted:FireClient(player, prop, primary, rig.alignPosition, rig.alignOrientation, session.boundingRadius)
end

local function onDragEnd(player: Player)
	releaseSession(player, "released", true)
end

local function onHeartbeat(dt: number)
	for player, session in sessionsByPlayer do
		if not session.primary.Parent then
			releaseSession(player, "invalid_primary", false)
			continue
		end

		local head = getHead(player)
		if not head then
			releaseSession(player, "missing_head", false)
			continue
		end

		local distance = (session.primary.AssemblyCenterOfMass - head.Position).Magnitude
		local leashDistance = Config.Drag.maxHoldDistance + session.boundingRadius + 3
		if distance > leashDistance then
			session.breachTime += dt
			if session.breachTime >= Config.Drag.leashGracePeriod then
				releaseSession(player, "leash", false)
			end
		else
			session.breachTime = 0
		end
	end
end

function DragService.setEquipService(service: any)
	equipService = service
end

function DragService.forceRelease(player: Player, reason: string?)
	releaseSession(player, reason or "forced", false)
end

function DragService.isDragging(player: Player): boolean
	return sessionsByPlayer[player] ~= nil
end

function DragService.start(remoteMap: any)
	remotes = remoteMap

	remotes.DragStartRequest.OnServerEvent:Connect(onDragStart)
	remotes.DragEndRequest.OnServerEvent:Connect(onDragEnd)
	RunService.Heartbeat:Connect(onHeartbeat)

	Players.PlayerRemoving:Connect(function(player)
		releaseSession(player, "left", false)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			releaseSession(player, "character_removed", false)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterRemoving:Connect(function()
			releaseSession(player, "character_removed", false)
		end)
	end
end

return DragService
