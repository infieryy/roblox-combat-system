--[[
	PickupService (server controller)
	------------------------------------------------------------------
	Authoritative owner of the pickup lifecycle:

	  1. Validates pickup requests (interactable? in reach? line of sight?
	     not anchored? not too heavy? not already held?).
	  2. Builds the AlignPosition / AlignOrientation hold rig and disables
	     collisions against the holder's own character.
	  3. Hands network ownership of the assembly to the holding player so
	     the held object simulates locally -> zero perceived lag.
	  4. Continuously "leashes" held objects: if a client drifts one too
	     far (exploit / desync) the server force-drops it.
	  5. Cleans everything up on drop, death, or disconnect.

	The client drives the rig's goal Position/CFrame each frame (it owns
	the physics), so no per-frame remotes are needed -- only pickup/drop.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupSystem = ReplicatedStorage:WaitForChild("PickupSystem")
local Config = require(PickupSystem:WaitForChild("Config"))
local PhysicsUtil = require(PickupSystem:WaitForChild("PhysicsUtil"))
local Remotes = require(PickupSystem:WaitForChild("Remotes"))

type HoldData = {
	player: Player,
	target: Instance,
	driver: BasePart,
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	noCollide: Folder,
	boundingRadius: number,
	breachTime: number,
}

local PickupService = {}

-- One hold per player; reverse map prevents two players grabbing the same object.
local heldByPlayer: { [Player]: HoldData } = {}
local holderOfObject: { [Instance]: Player } = {}

local remotes: Remotes.RemoteMap

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

local function getHead(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return character.PrimaryPart
end

local function getTargetPosition(target: Instance): Vector3
	if target:IsA("Model") then
		return target:GetPivot().Position
	elseif target:IsA("BasePart") then
		return target.Position
	end
	return Vector3.zero
end

-- Maximum distance a held object is allowed to sit from the head before
-- the leash trips (front-of-camera reach + object size + slack).
local function getLeashDistance(holdData: HoldData): number
	return Config.MaxHoldDistance + holdData.boundingRadius + 4
end

------------------------------------------------------------------
-- Validation
------------------------------------------------------------------

-- Returns (target, driver) when the request is legal, otherwise nil.
local function validatePickup(player: Player, hitInstance: Instance): (Instance?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local head = getHead(character)
	if not head then
		return nil, nil
	end

	local target = PhysicsUtil.resolveInteractable(hitInstance)
	if not target then
		return nil, nil
	end

	-- Already in someone's hands?
	if holderOfObject[target] then
		return nil, nil
	end

	local driver = PhysicsUtil.getDriverPart(target)
	if not driver or driver.Anchored then
		return nil, nil
	end

	-- Mass sanity (anti-grief / fling protection).
	if PhysicsUtil.getAssemblyMass(driver) > Config.MaxHoldMass then
		return nil, nil
	end

	-- Distance gate (server-authoritative, with latency slack).
	local targetPosition = getTargetPosition(target)
	local distance = (targetPosition - head.Position).Magnitude
	if distance > Config.MaxPickupDistance * Config.ServerDistanceTolerance then
		return nil, nil
	end

	-- Line-of-sight: cast from the head toward the object; the first thing
	-- hit must belong to the target, otherwise a wall is in the way.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local toTarget = targetPosition - head.Position
	local result = Workspace:Raycast(head.Position, toTarget + toTarget.Unit * 2, params)
	if result then
		local hit = result.Instance
		local belongs = hit == driver
			or (target:IsA("Model") and target:IsAncestorOf(hit))
			or PhysicsUtil.resolveInteractable(hit) == target
		if not belongs then
			return nil, nil
		end
	end

	return target, driver
end

------------------------------------------------------------------
-- Pickup / drop
------------------------------------------------------------------

local function dropHold(player: Player, holdData: HoldData?)
	holdData = holdData or heldByPlayer[player]
	if not holdData then
		return
	end

	heldByPlayer[player] = nil
	if holdData.target then
		holderOfObject[holdData.target] = nil
	end

	-- Return ownership before the constraints disappear so the physics
	-- engine settles the object cleanly.
	if holdData.driver and holdData.driver.Parent then
		PhysicsUtil.resetNetworkOwner(holdData.driver)
	end

	if holdData.alignPosition then
		holdData.alignPosition:Destroy()
	end
	if holdData.alignOrientation then
		holdData.alignOrientation:Destroy()
	end
	if holdData.attachment then
		holdData.attachment:Destroy()
	end
	if holdData.noCollide then
		holdData.noCollide:Destroy()
	end

	if player.Parent then
		remotes.PickupEnded:FireClient(player, holdData.target)
	end
end

local function beginHold(player: Player, target: Instance, driver: BasePart): HoldData
	local character = player.Character :: Model

	PhysicsUtil.prepareAssembly(target, driver)

	local parts = PhysicsUtil.collectParts(target)
	local noCollide = PhysicsUtil.disableCharacterCollisions(parts, character)
	local attachment, alignPosition, alignOrientation = PhysicsUtil.createHoldRig(target, driver)

	-- Hand ownership to the client AFTER the rig exists so the very first
	-- simulated frame already has the constraints in place.
	PhysicsUtil.setNetworkOwner(driver, player)

	local holdData: HoldData = {
		player = player,
		target = target,
		driver = driver,
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		noCollide = noCollide,
		boundingRadius = PhysicsUtil.getBoundingRadius(target),
		breachTime = 0,
	}

	heldByPlayer[player] = holdData
	holderOfObject[target] = player
	return holdData
end

------------------------------------------------------------------
-- Remote handlers
------------------------------------------------------------------

local function onRequestPickup(player: Player, hitInstance: any)
	if heldByPlayer[player] then
		return -- already holding something
	end
	if typeof(hitInstance) ~= "Instance" then
		return
	end

	local target, driver = validatePickup(player, hitInstance)
	if not target or not driver then
		return
	end

	local holdData = beginHold(player, target, driver)

	remotes.PickupGranted:FireClient(player, {
		object = target,
		driver = driver,
		attachment = holdData.attachment,
		alignPosition = holdData.alignPosition,
		alignOrientation = holdData.alignOrientation,
		boundingRadius = holdData.boundingRadius,
	})
end

local function onRequestDrop(player: Player)
	dropHold(player)
end

------------------------------------------------------------------
-- Anti-exploit leash loop
------------------------------------------------------------------

local function onHeartbeat(dt: number)
	for player, holdData in heldByPlayer do
		local character = player.Character
		local driver = holdData.driver

		if not character or not driver or not driver.Parent then
			dropHold(player, holdData)
			continue
		end

		local head = getHead(character)
		if not head then
			dropHold(player, holdData)
			continue
		end

		local distance = (driver.AssemblyCenterOfMass - head.Position).Magnitude
		if distance > getLeashDistance(holdData) then
			holdData.breachTime += dt
			if holdData.breachTime > Config.LeashGracePeriod then
				dropHold(player, holdData)
			end
		else
			holdData.breachTime = 0
		end
	end
end

------------------------------------------------------------------
-- Lifecycle wiring
------------------------------------------------------------------

local function bindPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		dropHold(player)
	end)
end

function PickupService.Start()
	remotes = Remotes.get()

	remotes.RequestPickup.OnServerEvent:Connect(onRequestPickup)
	remotes.RequestDrop.OnServerEvent:Connect(onRequestDrop)

	Players.PlayerRemoving:Connect(function(player)
		dropHold(player)
	end)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)

	RunService.Heartbeat:Connect(onHeartbeat)

	if Config.SpawnSampleObjects then
		local ok, sample = pcall(function()
			return require(script.Parent:WaitForChild("SampleObjects"))
		end)
		if ok and sample then
			sample.Spawn()
		end
	end
end

return PickupService
