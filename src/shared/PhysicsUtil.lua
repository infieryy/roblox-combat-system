--[[
	PhysicsUtil
	------------------------------------------------------------------
	Reusable, side-effect-light physics helpers shared by the client and
	server controllers. This module centralises all of the "tricky" bits
	that make holding arbitrary Blender imports feel good:

	  * Resolving an arbitrary hit Instance to its interactable root.
	  * Collecting every BasePart that makes up an object.
	  * Choosing a sensible driver part to attach constraints to.
	  * Welding loose parts into a single rigid assembly.
	  * Computing bounding box / center-of-mass data to place forces
	    accurately (Blender pivots are frequently off-center).
	  * Building the AlignPosition / AlignOrientation hold rig.
	  * Network ownership + per-character collision filtering.

	Constraint *creation* and network-ownership calls are server-only by
	nature, but the read helpers are safe to call from anywhere.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent:WaitForChild("Config"))

local PhysicsUtil = {}

------------------------------------------------------------------
-- Detection
------------------------------------------------------------------

-- Is this specific instance flagged as interactable (tag OR attribute)?
function PhysicsUtil.isInteractable(instance: Instance?): boolean
	if not instance or not instance.Parent then
		return false
	end
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return false
	end
	if CollectionService:HasTag(instance, Config.InteractTag) then
		return true
	end
	if instance:GetAttribute(Config.InteractAttribute) == true then
		return true
	end
	return false
end

-- Walk up from a raycast hit to the nearest interactable Model/BasePart.
-- Returns nil if nothing in the ancestry is interactable.
function PhysicsUtil.resolveInteractable(hit: Instance?): Instance?
	local node: Instance? = hit
	while node and node ~= Workspace do
		if PhysicsUtil.isInteractable(node) then
			return node
		end
		node = node.Parent
	end
	return nil
end

------------------------------------------------------------------
-- Part collection / driver selection
------------------------------------------------------------------

-- Every BasePart belonging to `target` (handles both Models and lone parts).
function PhysicsUtil.collectParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	elseif target:IsA("Model") then
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

-- The part we attach constraints to and hand network ownership of. We
-- prefer an explicit PrimaryPart, then fall back to the heaviest part so
-- the constraint rig sits on the most stable element of the assembly.
function PhysicsUtil.getDriverPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		if target.PrimaryPart then
			return target.PrimaryPart
		end
		local best: BasePart? = nil
		local bestMass = -1
		for _, part in PhysicsUtil.collectParts(target) do
			local mass = part:GetMass()
			if mass > bestMass then
				best, bestMass = part, mass
			end
		end
		return best
	end
	return nil
end

------------------------------------------------------------------
-- Bounding box / mass (Blender-import friendly)
------------------------------------------------------------------

-- World-space size of the object. Uses Model:GetBoundingBox() which is
-- robust against off-center Blender pivots.
function PhysicsUtil.getBoundingSize(target: Instance): Vector3
	if target:IsA("Model") then
		local _cf, size = target:GetBoundingBox()
		return size
	elseif target:IsA("BasePart") then
		return target.Size
	end
	return Vector3.one
end

-- Half the diagonal of the bounding box; a good "radius" for spacing the
-- object away from the camera and for moment-of-inertia approximations.
function PhysicsUtil.getBoundingRadius(target: Instance): number
	return PhysicsUtil.getBoundingSize(target).Magnitude / 2
end

-- Total mass of the whole assembly the driver belongs to.
function PhysicsUtil.getAssemblyMass(driver: BasePart): number
	return driver.AssemblyMass
end

------------------------------------------------------------------
-- Assembly preparation
------------------------------------------------------------------

-- Make sure the object is a single, unanchored rigid body so it can be
-- dragged as one unit. Loose parts are welded to the driver exactly once
-- (tracked via an attribute) so repeated pickups never stack welds.
function PhysicsUtil.prepareAssembly(target: Instance, driver: BasePart)
	local parts = PhysicsUtil.collectParts(target)

	-- Unanchor first; SetNetworkOwner and the align constraints both
	-- require the assembly to be free to simulate.
	for _, part in parts do
		part.Anchored = false
	end

	if target:GetAttribute("PickupPrepared") then
		return
	end

	for _, part in parts do
		if part ~= driver and part.AssemblyRootPart ~= driver.AssemblyRootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupWeld"
			weld.Part0 = driver
			weld.Part1 = part
			weld.Parent = driver
		end
	end

	target:SetAttribute("PickupPrepared", true)
end

------------------------------------------------------------------
-- Hold rig (AlignPosition + AlignOrientation)
------------------------------------------------------------------

-- An attachment placed exactly at the assembly's center of mass with the
-- driver's orientation. Driving this attachment means forces act through
-- the COM (no parasitic spin) and aligning its orientation aligns the
-- object's orientation 1:1.
function PhysicsUtil.createHoldAttachment(driver: BasePart): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = "PickupHoldAttachment"
	attachment.Parent = driver
	-- WorldCFrame: COM position + driver rotation (identity relative rotation).
	attachment.WorldCFrame = driver.CFrame.Rotation + driver.AssemblyCenterOfMass
	return attachment
end

-- Build the full hold rig on the server. Forces/torques are scaled by the
-- object's mass and size so light and heavy props feel equally controlled
-- and nothing gets flung. Goals are initialised to the *current* pose to
-- avoid a snap when the rig switches on.
function PhysicsUtil.createHoldRig(target: Instance, driver: BasePart)
	local mass = PhysicsUtil.getAssemblyMass(driver)
	local radius = PhysicsUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity

	local attachment = PhysicsUtil.createHoldAttachment(driver)

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = mass * gravity * Config.PositionForceMultiplier
	alignPosition.MaxVelocity = Config.PositionMaxVelocity
	alignPosition.Responsiveness = Config.PositionResponsiveness
	alignPosition.Position = attachment.WorldPosition
	alignPosition.Parent = driver

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = mass * (radius * radius) * Config.OrientationTorqueMultiplier
	alignOrientation.MaxAngularVelocity = Config.OrientationMaxAngularVelocity
	alignOrientation.Responsiveness = Config.OrientationResponsiveness
	alignOrientation.CFrame = driver.CFrame.Rotation
	alignOrientation.Parent = driver

	return attachment, alignPosition, alignOrientation
end

------------------------------------------------------------------
-- Network ownership (server only)
------------------------------------------------------------------

function PhysicsUtil.setNetworkOwner(driver: BasePart, player: Player?): boolean
	if driver.Anchored then
		return false
	end
	local ok = pcall(function()
		driver:SetNetworkOwner(player)
	end)
	return ok
end

function PhysicsUtil.resetNetworkOwner(driver: BasePart)
	pcall(function()
		driver:SetNetworkOwnershipAuto()
	end)
end

------------------------------------------------------------------
-- Collision filtering (server only)
------------------------------------------------------------------

-- Disable collisions between every held part and every part of the
-- holder's character using NoCollisionConstraints. This is surgical: the
-- object still collides with walls, the ground and *other* players, but
-- never glitches against the person carrying it. The returned folder
-- holds all constraints so a single :Destroy() restores normal collisions.
function PhysicsUtil.disableCharacterCollisions(parts: { BasePart }, character: Model): Folder
	local container = Instance.new("Folder")
	container.Name = "PickupNoCollision"

	local characterParts: { BasePart } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(characterParts, descendant)
		end
	end

	for _, heldPart in parts do
		for _, charPart in characterParts do
			local constraint = Instance.new("NoCollisionConstraint")
			constraint.Part0 = heldPart
			constraint.Part1 = charPart
			constraint.Parent = container
		end
	end

	container.Parent = parts[1]
	return container
end

return PhysicsUtil
