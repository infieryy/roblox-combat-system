local CollectionService = game:GetService("CollectionService")

local PhysicsPickupUtil = {}

export type ConstraintBundle = {
	anchorPart: Part,
	anchorAttachment: Attachment,
	objectAttachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	noCollisionConstraints: { NoCollisionConstraint },
}

local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"

local function hasInteractableMarker(instance: Instance): boolean
	if CollectionService:HasTag(instance, INTERACTABLE_TAG) then
		return true
	end

	return instance:GetAttribute(INTERACTABLE_ATTRIBUTE) == true
end

function PhysicsPickupUtil.findInteractableFromHit(hitInstance: Instance?): Instance?
	local cursor: Instance? = hitInstance
	while cursor do
		if (cursor:IsA("Model") or cursor:IsA("BasePart")) and hasInteractableMarker(cursor) then
			return cursor
		end
		cursor = cursor.Parent
	end

	return nil
end

function PhysicsPickupUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	end

	local basePart = target :: BasePart
	return basePart.CFrame, basePart.Size
end

function PhysicsPickupUtil.getRootPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end

	local model = target :: Model
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	if #parts == 0 then
		return nil
	end

	local bboxCFrame = PhysicsPickupUtil.getBoundingBox(model)
	table.sort(parts, function(a, b)
		local aDistance = (a.Position - bboxCFrame.Position).Magnitude
		local bDistance = (b.Position - bboxCFrame.Position).Magnitude
		return aDistance < bDistance
	end)

	return parts[1]
end

function PhysicsPickupUtil.getBaseParts(target: Instance): { BasePart }
	if target:IsA("BasePart") then
		return { target }
	end

	local parts = {}
	for _, descendant in (target :: Model):GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

function PhysicsPickupUtil.createAnchorPart(): (Part, Attachment)
	local anchorPart = Instance.new("Part")
	anchorPart.Name = "PickupHoldAnchor"
	anchorPart.Transparency = 1
	anchorPart.Size = Vector3.new(0.2, 0.2, 0.2)
	anchorPart.Anchored = true
	anchorPart.CanCollide = false
	anchorPart.CanQuery = false
	anchorPart.CanTouch = false
	anchorPart.Massless = true
	anchorPart.Parent = workspace

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "PickupHoldAnchorAttachment"
	anchorAttachment.Parent = anchorPart

	return anchorPart, anchorAttachment
end

function PhysicsPickupUtil.createConstraintBundle(target: Instance, rootPart: BasePart): ConstraintBundle
	local bboxCFrame = PhysicsPickupUtil.getBoundingBox(target)

	local anchorPart, anchorAttachment = PhysicsPickupUtil.createAnchorPart()

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "PickupObjectAttachment"
	objectAttachment.Parent = rootPart
	objectAttachment.WorldCFrame = bboxCFrame

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = anchorAttachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = 120000
	alignPosition.MaxVelocity = math.huge
	alignPosition.Responsiveness = 30
	alignPosition.RigidityEnabled = false
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = anchorAttachment
	alignOrientation.MaxTorque = 120000
	alignOrientation.Responsiveness = 35
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.RigidityEnabled = false
	alignOrientation.PrimaryAxisOnly = false
	alignOrientation.Parent = rootPart

	return {
		anchorPart = anchorPart,
		anchorAttachment = anchorAttachment,
		objectAttachment = objectAttachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		noCollisionConstraints = {},
	}
end

function PhysicsPickupUtil.setNoCollisionWithCharacter(target: Instance, character: Model): { NoCollisionConstraint }
	local constraints = {}
	local objectParts = PhysicsPickupUtil.getBaseParts(target)

	local characterParts = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(characterParts, descendant)
		end
	end

	for _, objectPart in objectParts do
		for _, characterPart in characterParts do
			local noCollision = Instance.new("NoCollisionConstraint")
			noCollision.Name = "PickupNoCollision"
			noCollision.Part0 = objectPart
			noCollision.Part1 = characterPart
			noCollision.Parent = objectPart
			table.insert(constraints, noCollision)
		end
	end

	return constraints
end

function PhysicsPickupUtil.setNetworkOwner(target: Instance, owner: Player?)
	for _, part in PhysicsPickupUtil.getBaseParts(target) do
		if not part.Anchored then
			pcall(function()
				part:SetNetworkOwner(owner)
			end)
		end
	end
end

function PhysicsPickupUtil.resetAssemblyVelocity(target: Instance)
	for _, part in PhysicsPickupUtil.getBaseParts(target) do
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
end

function PhysicsPickupUtil.computeAnchorCFrame(cameraCFrame: CFrame, holdDistance: number, holdHeight: number, rotation: CFrame): CFrame
	return cameraCFrame * CFrame.new(0, holdHeight, -holdDistance) * rotation
end

function PhysicsPickupUtil.destroyConstraintBundle(bundle: ConstraintBundle)
	for _, noCollision in bundle.noCollisionConstraints do
		if noCollision.Parent then
			noCollision:Destroy()
		end
	end

	if bundle.alignPosition.Parent then
		bundle.alignPosition:Destroy()
	end
	if bundle.alignOrientation.Parent then
		bundle.alignOrientation:Destroy()
	end
	if bundle.objectAttachment.Parent then
		bundle.objectAttachment:Destroy()
	end
	if bundle.anchorAttachment.Parent then
		bundle.anchorAttachment:Destroy()
	end
	if bundle.anchorPart.Parent then
		bundle.anchorPart:Destroy()
	end
end

return PhysicsPickupUtil
