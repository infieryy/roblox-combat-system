--!strict
--[[
	PhysicsUtil
	-----------
	A reusable, side-effect-light physics utility module. It knows nothing about
	remotes or input; it only answers questions about geometry / mass and builds
	the constraint rig used to hold an object.

	It deliberately accounts for the quirks of meshes imported from Blender:
	  * Models may have no PrimaryPart set.
	  * MeshParts frequently have an off-centre pivot / origin.
	  * The visual centre and the centre of mass rarely match.
	By anchoring the hold attachment to the *assembly centre of mass* and
	enabling ApplyAtCenterOfMass on the AlignPosition, the object is dragged from
	its true balance point, so it floats stably instead of tumbling.
]]

local Config = require(script.Parent.Config)

local PhysicsUtil = {}

export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

export type CollisionSnapshot = { [BasePart]: string }

------------------------------------------------------------------
-- Part / geometry helpers
------------------------------------------------------------------

-- Collect every BasePart that makes up an instance (the instance itself if it
-- is a part, plus any descendant parts for Models).
function PhysicsUtil.getParts(instance: Instance): { BasePart }
	local parts: { BasePart } = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Resolve the single part that should anchor the constraints. Prefers an
-- explicitly set PrimaryPart, otherwise falls back to the largest part by
-- volume (a robust default for Blender Models with no PrimaryPart).
function PhysicsUtil.getPrimaryPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end

	if instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart
		end

		local best: BasePart? = nil
		local bestVolume = -1
		for _, part in PhysicsUtil.getParts(instance) do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > bestVolume then
				best = part
				bestVolume = volume
			end
		end
		return best
	end

	return nil
end

-- World-space bounding box (CFrame at the centre, Size of the box).
-- Uses Model:GetBoundingBox() so it respects the actual visual extents of a
-- Blender import rather than any mis-placed pivot.
function PhysicsUtil.getBoundingBox(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	return CFrame.identity, Vector3.zero
end

-- Half the bounding-box diagonal: a single "radius" number we can use to scale
-- how far away big objects should float.
function PhysicsUtil.getRadius(instance: Instance): number
	local _, size = PhysicsUtil.getBoundingBox(instance)
	return size.Magnitude * 0.5
end

-- How far in front of the camera the object should hover, scaled to its size
-- and clamped to a comfortable range.
function PhysicsUtil.getHoldDistance(instance: Instance): number
	local radius = PhysicsUtil.getRadius(instance)
	local distance = Config.HoldDistanceBase + radius * Config.HoldDistancePadding
	return math.clamp(distance, Config.HoldDistanceMin, Config.HoldDistanceMax)
end

------------------------------------------------------------------
-- Constraint rig
------------------------------------------------------------------

-- Build the AlignPosition + AlignOrientation rig on the given primary part.
-- The attachment is placed exactly at the assembly's centre of mass so the
-- object is carried from its balance point (key for off-pivot Blender meshes).
function PhysicsUtil.createHoldRig(primaryPart: BasePart): HoldRig
	local mass = math.max(primaryPart.AssemblyMass, 1)
	local gravity = workspace.Gravity

	-- Attachment sits at the centre of mass but stays axis-aligned with the part
	-- (rotation offset = identity). That keeps the attachment's WORLD orientation
	-- equal to the part's world orientation, so the AlignOrientation goal CFrame
	-- maps directly to the part's desired world orientation. We use
	-- PointToObjectSpace so only the COM position is baked in, never a rotation.
	local attachment = Instance.new("Attachment")
	attachment.Name = "PickupHoldAttachment"
	local comWorld = primaryPart.AssemblyCenterOfMass
	attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(comWorld))
	attachment.Parent = primaryPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupHoldAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = mass * gravity * Config.ForceMultiplier
	alignPosition.MaxVelocity = Config.PositionMaxVelocity
	alignPosition.Responsiveness = Config.PositionResponsiveness
	alignPosition.Position = comWorld
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupHoldAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = mass * Config.TorqueMultiplier
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

-- Tear down a rig created by createHoldRig.
function PhysicsUtil.destroyHoldRig(rig: HoldRig?)
	if not rig then
		return
	end
	if rig.alignPosition then
		rig.alignPosition:Destroy()
	end
	if rig.alignOrientation then
		rig.alignOrientation:Destroy()
	end
	if rig.attachment then
		rig.attachment:Destroy()
	end
end

------------------------------------------------------------------
-- Collision groups
------------------------------------------------------------------

-- Move every part of an instance into a collision group, returning a snapshot
-- of the previous groups so they can be restored later.
function PhysicsUtil.applyCollisionGroup(instance: Instance, group: string): CollisionSnapshot
	local snapshot: CollisionSnapshot = {}
	for _, part in PhysicsUtil.getParts(instance) do
		snapshot[part] = part.CollisionGroup
		part.CollisionGroup = group
	end
	return snapshot
end

-- Restore collision groups captured by applyCollisionGroup.
function PhysicsUtil.restoreCollisionGroup(snapshot: CollisionSnapshot?)
	if not snapshot then
		return
	end
	for part, group in snapshot do
		if part and part.Parent then
			part.CollisionGroup = group
		end
	end
end

return PhysicsUtil
