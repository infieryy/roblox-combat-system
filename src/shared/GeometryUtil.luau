--!strict

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")

export type HoldRig = {
	attachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
}

local GeometryUtil = {}

function GeometryUtil.getPrimaryPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if not target:IsA("Model") then
		return nil
	end
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

function GeometryUtil.getParts(target: Instance): { BasePart }
	local parts = {}
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

function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	end
	if target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

function GeometryUtil.getBoundingRadius(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return size.Magnitude / 2
end

function GeometryUtil.getMass(target: Instance): number
	local primary = GeometryUtil.getPrimaryPart(target)
	if not primary then
		return 0
	end
	return primary.AssemblyMass
end

function GeometryUtil.resolveInteractable(hit: Instance?, tag: string, attribute: string): Instance?
	local cursor = hit
	while cursor and cursor ~= Workspace do
		if CollectionService:HasTag(cursor, tag) or cursor:GetAttribute(attribute) == true then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

function GeometryUtil.unanchor(target: Instance): { [BasePart]: boolean }
	local snapshots: { [BasePart]: boolean } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshots[part] = part.Anchored
		part.Anchored = false
	end
	return snapshots
end

function GeometryUtil.restoreAnchors(snapshots: { [BasePart]: boolean })
	for part, anchored in snapshots do
		if part.Parent then
			part.Anchored = anchored
		end
	end
end

function GeometryUtil.weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
	local welds = {}
	if not target:IsA("Model") then
		return welds
	end

	for _, part in GeometryUtil.getParts(target) do
		if part ~= primaryPart and not part.Anchored then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "DragWeld"
			weld.Part0 = primaryPart
			weld.Part1 = part
			weld.Parent = primaryPart
			table.insert(welds, weld)
		end
	end
	return welds
end

function GeometryUtil.ensureCollisionGroups(characterGroup: string, heldGroup: string)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, characterGroup)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, heldGroup)
	PhysicsService:CollisionGroupSetCollidable(characterGroup, heldGroup, false)
end

function GeometryUtil.setCollisionGroup(target: Instance, groupName: string): { [BasePart]: string }
	local snapshots: { [BasePart]: string } = {}
	for _, part in GeometryUtil.getParts(target) do
		snapshots[part] = part.CollisionGroup
		part.CollisionGroup = groupName
	end
	return snapshots
end

function GeometryUtil.restoreCollisionGroups(snapshots: { [BasePart]: string })
	for part, group in snapshots do
		if part.Parent then
			part.CollisionGroup = group
		end
	end
end

function GeometryUtil.createHoldRig(
	target: Instance,
	primaryPart: BasePart,
	config: {
		positionResponsiveness: number,
		orientationResponsiveness: number,
		maxVelocity: number,
		maxAngularVelocity: number,
		positionForceMultiplier: number,
		orientationTorqueMultiplier: number,
	}
): HoldRig
	local mass = primaryPart.AssemblyMass
	local radius = GeometryUtil.getBoundingRadius(target)
	local gravity = Workspace.Gravity
	local boxCF, _boxSize = GeometryUtil.getBoundingBox(target)
	local comOffset = primaryPart.CFrame:PointToObjectSpace(boxCF.Position)

	local attachment = Instance.new("Attachment")
	attachment.Name = "DragHoldAttachment"
	attachment.CFrame = CFrame.new(comOffset)
	attachment.Parent = primaryPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "DragAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.ReactionForceEnabled = false
	alignPosition.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	alignPosition.MaxForce = mass * gravity * config.positionForceMultiplier
	alignPosition.MaxVelocity = config.maxVelocity
	alignPosition.Responsiveness = config.positionResponsiveness
	alignPosition.Position = boxCF.Position
	alignPosition.Parent = primaryPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "DragAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = mass * radius * radius * config.orientationTorqueMultiplier
	alignOrientation.MaxAngularVelocity = config.maxAngularVelocity
	alignOrientation.Responsiveness = config.orientationResponsiveness
	alignOrientation.CFrame = primaryPart.CFrame.Rotation
	alignOrientation.Parent = primaryPart

	return {
		attachment = attachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

function GeometryUtil.destroyHoldRig(rig: HoldRig?)
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

return GeometryUtil
