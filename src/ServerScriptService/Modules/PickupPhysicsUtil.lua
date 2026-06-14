local PickupPhysicsUtil = {}

export type ObjectData = {
	object: Instance,
	rootPart: BasePart,
	parts: { BasePart },
	boundingCenterWorld: Vector3,
}

export type HoldRig = {
	targetPart: Part,
	targetAttachment: Attachment,
	objectAttachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	noCollisionConstraints: { NoCollisionConstraint },
	destroy: () -> (),
}

local function getBaseParts(object: Instance): { BasePart }
	if object:IsA("BasePart") then
		return { object }
	end

	local parts = {}
	for _, descendant in object:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

local function pickRootPart(object: Instance, parts: { BasePart }): BasePart?
	if object:IsA("Model") then
		local model = object :: Model
		if model.PrimaryPart then
			return model.PrimaryPart
		end
	end

	local bestPart: BasePart? = nil
	local bestMass = -math.huge

	for _, part in parts do
		if not part.Anchored then
			local mass = part:GetMass()
			if mass > bestMass then
				bestMass = mass
				bestPart = part
			end
		end
	end

	if bestPart then
		return bestPart
	end

	return parts[1]
end

local function getBoundingCenterWorld(object: Instance, rootPart: BasePart): Vector3
	if object:IsA("Model") then
		local model = object :: Model
		local boundingBoxCFrame = model:GetBoundingBox()
		return boundingBoxCFrame.Position
	end

	return rootPart.Position
end

function PickupPhysicsUtil.getObjectData(object: Instance): ObjectData?
	if not (object:IsA("Model") or object:IsA("BasePart")) then
		return nil
	end

	local parts = getBaseParts(object)
	if #parts == 0 then
		return nil
	end

	local rootPart = pickRootPart(object, parts)
	if not rootPart then
		return nil
	end

	local boundingCenterWorld = getBoundingCenterWorld(object, rootPart)
	return {
		object = object,
		rootPart = rootPart,
		parts = parts,
		boundingCenterWorld = boundingCenterWorld,
	}
end

function PickupPhysicsUtil.hasAnchoredParts(parts: { BasePart }): boolean
	for _, part in parts do
		if part.Anchored then
			return true
		end
	end

	return false
end

function PickupPhysicsUtil.setNetworkOwnership(rootPart: BasePart, player: Player?)
	if rootPart.Anchored then
		return
	end

	local success = pcall(function()
		rootPart:SetNetworkOwner(player)
	end)

	if not success then
		warn(string.format("Failed to set network owner for %s", rootPart:GetFullName()))
	end
end

function PickupPhysicsUtil.createNoCollisionConstraints(
	objectParts: { BasePart },
	character: Model
): { NoCollisionConstraint }
	local constraints = {}
	local characterParts = {}

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(characterParts, descendant)
		end
	end

	for _, objectPart in objectParts do
		for _, characterPart in characterParts do
			local constraint = Instance.new("NoCollisionConstraint")
			constraint.Part0 = objectPart
			constraint.Part1 = characterPart
			constraint.Parent = objectPart
			table.insert(constraints, constraint)
		end
	end

	return constraints
end

function PickupPhysicsUtil.createHoldRig(
	objectData: ObjectData,
	character: Model,
	initialTargetCFrame: CFrame
): HoldRig
	local rootPart = objectData.rootPart

	local targetPart = Instance.new("Part")
	targetPart.Name = "PickupTargetPart"
	targetPart.Size = Vector3.new(0.25, 0.25, 0.25)
	targetPart.Transparency = 1
	targetPart.CanCollide = false
	targetPart.CanTouch = false
	targetPart.CanQuery = false
	targetPart.Anchored = true
	targetPart.Locked = true
	targetPart.CFrame = initialTargetCFrame
	targetPart.Parent = workspace

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "PickupTargetAttachment"
	targetAttachment.Parent = targetPart

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "PickupObjectAttachment"
	objectAttachment.Position = rootPart.CFrame:PointToObjectSpace(objectData.boundingCenterWorld)
	objectAttachment.Parent = rootPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = targetAttachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.Responsiveness = 40
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = math.huge
	alignPosition.MaxVelocity = math.huge
	alignPosition.ReactionForceEnabled = false
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = targetAttachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Responsiveness = 40
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = math.huge
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.PrimaryAxisOnly = false
	alignOrientation.Parent = rootPart

	local noCollisionConstraints = PickupPhysicsUtil.createNoCollisionConstraints(objectData.parts, character)

	local destroyed = false
	local function destroy()
		if destroyed then
			return
		end
		destroyed = true

		for _, constraint in noCollisionConstraints do
			constraint:Destroy()
		end
		noCollisionConstraints = {}

		alignPosition:Destroy()
		alignOrientation:Destroy()
		objectAttachment:Destroy()
		targetAttachment:Destroy()
		targetPart:Destroy()
	end

	return {
		targetPart = targetPart,
		targetAttachment = targetAttachment,
		objectAttachment = objectAttachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		noCollisionConstraints = noCollisionConstraints,
		destroy = destroy,
	}
end

return PickupPhysicsUtil
