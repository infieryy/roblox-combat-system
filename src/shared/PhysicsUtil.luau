--!nonstrict
--[[
	PhysicsUtil
	-----------------------------------------------------------------------------
	Reusable, stateless physics helpers for the pickup system. Everything that
	touches geometry, mass, welding, constraints or collision groups lives here
	so both the server controller and (read-only parts of) the client can share
	one battle-tested implementation.

	Designed with Blender imports in mind: custom/off-centre pivots are common,
	so we drive objects by their *visual bounding-box centre* rather than by a
	possibly-garbage PrimaryPart origin.
--]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local PhysicsUtil = {}

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

-- Returns the BasePart we should treat as the assembly root for an interactable.
-- For a Model: PrimaryPart if set, otherwise the largest BasePart by volume.
-- For a BasePart: itself.
function PhysicsUtil.getPrimaryPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	elseif target:IsA("Model") then
		if target.PrimaryPart then
			return target.PrimaryPart
		end
		local best: BasePart? = nil
		local bestVolume = -1
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("BasePart") then
				local size = descendant.Size
				local volume = size.X * size.Y * size.Z
				if volume > bestVolume then
					best = descendant
					bestVolume = volume
				end
			end
		end
		return best
	end
	return nil
end

-- Returns (centreCFrame, size) of the world-space, model-oriented bounding box.
-- Handles Blender off-centre origins gracefully because Model:GetBoundingBox()
-- is computed from actual geometry, not from the pivot.
function PhysicsUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- Total mass of the whole assembly the target belongs to.
function PhysicsUtil.getMass(target: Instance): number
	local primary = PhysicsUtil.getPrimaryPart(target)
	if primary then
		return primary.AssemblyMass
	end
	return 0
end

-- Collects every BasePart belonging to `target` (inclusive of itself).
function PhysicsUtil.getParts(target: Instance): { BasePart }
	local parts = {}
	if target:IsA("BasePart") then
		table.insert(parts, target)
	end
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--------------------------------------------------------------------------------
-- Interactable resolution
--------------------------------------------------------------------------------

-- Walks up from `hit` toward (but not including) workspace, returning the first
-- ancestor (or the hit itself) flagged as interactable via tag or attribute.
function PhysicsUtil.resolvePickupRoot(hit: Instance?, tag: string, attribute: string): Instance?
	local node = hit
	while node and node ~= workspace do
		if CollectionService:HasTag(node, tag) or node:GetAttribute(attribute) == true then
			return node
		end
		node = node.Parent
	end
	return nil
end

--------------------------------------------------------------------------------
-- Welding (make multi-part imports behave as one rigid assembly)
--------------------------------------------------------------------------------

-- Rigidly welds every loose, unanchored BasePart in `model` to `primaryPart`
-- using WeldConstraints. Returns the list of welds we created so they can be
-- removed again on drop. Already-welded assemblies just gain harmless extra
-- constraints; nothing is mutated destructively.
function PhysicsUtil.weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local created = {}
	if not target:IsA("Model") then
		return created
	end
	for _, part in PhysicsUtil.getParts(target) do
		if part ~= primaryPart and not part.Anchored then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupWeld"
			weld.Part0 = primaryPart
			weld.Part1 = part
			weld.Parent = primaryPart
			table.insert(created, weld)
		end
	end
	return created
end

--------------------------------------------------------------------------------
-- Anchoring
--------------------------------------------------------------------------------

-- Unanchors every part (required for network ownership + constraint dragging)
-- while recording original states so they can be restored exactly on drop.
function PhysicsUtil.unanchor(target: Instance): { [BasePart]: boolean }
	local original = {}
	for _, part in PhysicsUtil.getParts(target) do
		original[part] = part.Anchored
		part.Anchored = false
	end
	return original
end

function PhysicsUtil.restoreAnchors(original: { [BasePart]: boolean })
	for part, anchored in original do
		if part and part.Parent then
			part.Anchored = anchored
		end
	end
end

--------------------------------------------------------------------------------
-- Collision groups
--------------------------------------------------------------------------------

-- Registers the two collision groups and wires them so held objects never
-- collide with characters, but still collide with the Default world (walls).
-- Idempotent and safe to call from multiple places.
function PhysicsUtil.ensureCollisionGroups(characterGroup: string, heldGroup: string)
	-- RegisterCollisionGroup throws if the group already exists, hence pcall.
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, characterGroup)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, heldGroup)
	PhysicsService:CollisionGroupSetCollidable(characterGroup, heldGroup, false)
end

-- Moves every part of `target` into `groupName`, returning a map of the
-- previous groups for later restoration.
function PhysicsUtil.setCollisionGroup(target: Instance, groupName: string): { [BasePart]: string }
	local original = {}
	for _, part in PhysicsUtil.getParts(target) do
		original[part] = part.CollisionGroup
		part.CollisionGroup = groupName
	end
	return original
end

function PhysicsUtil.restoreCollisionGroups(original: { [BasePart]: string })
	for part, group in original do
		if part and part.Parent then
			part.CollisionGroup = group
		end
	end
end

--------------------------------------------------------------------------------
-- Hold constraints (the heart of the smooth drag)
--------------------------------------------------------------------------------

export type HoldConfig = {
	MaxForce: number,
	MaxTorque: number,
	MaxVelocity: number,
	PositionResponsiveness: number,
	OrientationResponsiveness: number,
}

export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

-- Builds the AlignPosition + AlignOrientation rig used to drag an object.
--
-- The attachment is placed at the *visual bounding-box centre* (converted into
-- the primary part's object space) so that Blender meshes with weird origins
-- still hover centred in front of the camera. Both constraints run in
-- OneAttachment mode, meaning we steer them purely by writing
-- `alignPosition.Position` and `alignOrientation.CFrame` each frame.
function PhysicsUtil.createHoldRig(target: Instance, primaryPart: BasePart, config: HoldConfig): HoldRig
	local boxCFrame = PhysicsUtil.getBoundingBox(target)
	-- Offset (object space) from the primary part to the geometric centre.
	local centreOffset = primaryPart.CFrame:PointToObjectSpace(boxCFrame.Position)

	local attachment = Instance.new("Attachment")
	attachment.Name = "PickupHoldAttachment"
	-- Position-only offset; identity rotation keeps orientation math simple
	-- (attachment orientation == primary part orientation).
	attachment.CFrame = CFrame.new(centreOffset)
	attachment.Parent = primaryPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = false
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	alignPosition.MaxForce = config.MaxForce
	alignPosition.MaxVelocity = config.MaxVelocity
	alignPosition.Responsiveness = config.PositionResponsiveness
	alignPosition.Position = boxCFrame.Position
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = config.MaxTorque
	alignOrientation.Responsiveness = config.OrientationResponsiveness
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

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

return PhysicsUtil
