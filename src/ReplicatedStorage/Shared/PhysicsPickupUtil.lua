--!strict

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

export type InteractableRoot = BasePart | Model

export type HoldConstraintBundle = {
	RootPart: BasePart,
	TargetRoot: InteractableRoot,
	ObjectAttachment: Attachment,
	AnchorPart: Part,
	AnchorAttachment: Attachment,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	RuntimeFolder: Folder,
	CollisionConstraints: { NoCollisionConstraint },
}

local PhysicsPickupUtil = {}

local function orientationOnly(cframe: CFrame): CFrame
	return cframe - cframe.Position
end

function PhysicsPickupUtil.GetOrientationOnly(cframe: CFrame): CFrame
	return orientationOnly(cframe)
end

function PhysicsPickupUtil.IsInteractable(instance: Instance): boolean
	return CollectionService:HasTag(instance, "Interactable") or instance:GetAttribute("Interactable") == true
end

function PhysicsPickupUtil.FindInteractableRoot(instance: Instance?): InteractableRoot?
	local cursor = instance
	while cursor and cursor ~= Workspace do
		if PhysicsPickupUtil.IsInteractable(cursor) and (cursor:IsA("Model") or cursor:IsA("BasePart")) then
			return cursor
		end
		cursor = cursor.Parent
	end

	return nil
end

function PhysicsPickupUtil.GetBaseParts(targetRoot: InteractableRoot): { BasePart }
	if targetRoot:IsA("BasePart") then
		return { targetRoot }
	end

	local parts = {}
	for _, descendant in targetRoot:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

function PhysicsPickupUtil.ResolveRootPart(targetRoot: InteractableRoot): BasePart?
	if targetRoot:IsA("BasePart") then
		return targetRoot
	end

	if targetRoot.PrimaryPart then
		return targetRoot.PrimaryPart
	end

	for _, descendant in targetRoot:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end

	return nil
end

function PhysicsPickupUtil.GetBoundingCenter(targetRoot: InteractableRoot): Vector3
	if targetRoot:IsA("BasePart") then
		return targetRoot.Position
	end

	local boundingBox = targetRoot:GetBoundingBox()
	return boundingBox.Position
end

function PhysicsPickupUtil.GetPivot(targetRoot: InteractableRoot): CFrame
	if targetRoot:IsA("BasePart") then
		return targetRoot.CFrame
	end

	return targetRoot:GetPivot()
end

function PhysicsPickupUtil.InstanceBelongsToRoot(instance: Instance, targetRoot: InteractableRoot): boolean
	return instance == targetRoot or instance:IsDescendantOf(targetRoot)
end

function PhysicsPickupUtil.SetNetworkOwner(targetRoot: InteractableRoot, owner: Player?)
	for _, part in PhysicsPickupUtil.GetBaseParts(targetRoot) do
		if not part.Anchored then
			local success = pcall(function()
				part:SetNetworkOwner(owner)
			end)

			if not success then
				-- Some part types may reject ownership changes; continue safely.
			end
		end
	end
end

function PhysicsPickupUtil.CalculateAttachmentLocalPosition(rootPart: BasePart, targetRoot: InteractableRoot): Vector3
	local center = PhysicsPickupUtil.GetBoundingCenter(targetRoot)
	return rootPart.CFrame:PointToObjectSpace(center)
end

function PhysicsPickupUtil.CalculateInitialRotationOffset(cameraCFrame: CFrame, rootPart: BasePart): CFrame
	local cameraRotation = orientationOnly(cameraCFrame)
	local objectRotation = orientationOnly(rootPart.CFrame)
	return cameraRotation:ToObjectSpace(objectRotation)
end

function PhysicsPickupUtil.ComposeHoldCFrame(cameraCFrame: CFrame, holdDistance: number, rotationOffset: CFrame): CFrame
	local holdPosition = (cameraCFrame * CFrame.new(0, 0, -holdDistance)).Position
	local worldRotation = orientationOnly(cameraCFrame) * rotationOffset
	return CFrame.new(holdPosition) * worldRotation
end

function PhysicsPickupUtil.CreateHoldConstraints(
	targetRoot: InteractableRoot,
	rootPart: BasePart,
	playerUserId: number
): HoldConstraintBundle
	local assemblyMass = math.max(rootPart.AssemblyMass, 1)
	local maxForce = math.max(assemblyMass * 20_000, 200_000)
	local maxTorque = math.max(assemblyMass * 30_000, 200_000)

	local runtimeFolder = Instance.new("Folder")
	runtimeFolder.Name = ("PickupRuntime_%d"):format(playerUserId)
	runtimeFolder.Parent = rootPart

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "PickupObjectAttachment"
	objectAttachment.Position = PhysicsPickupUtil.CalculateAttachmentLocalPosition(rootPart, targetRoot)
	objectAttachment.Parent = rootPart

	local anchorPart = Instance.new("Part")
	anchorPart.Name = ("PickupAnchor_%d"):format(playerUserId)
	anchorPart.Size = Vector3.new(0.2, 0.2, 0.2)
	anchorPart.Transparency = 1
	anchorPart.CanCollide = false
	anchorPart.CanTouch = false
	anchorPart.CanQuery = false
	anchorPart.Massless = true
	anchorPart.Anchored = true
	anchorPart.CFrame = rootPart.CFrame
	anchorPart.Parent = Workspace

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "PickupAnchorAttachment"
	anchorAttachment.Parent = anchorPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = anchorAttachment
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.Responsiveness = 45
	alignPosition.MaxForce = maxForce
	alignPosition.MaxVelocity = 150
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ReactionForceEnabled = false
	alignPosition.RigidityEnabled = false
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = anchorAttachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Responsiveness = 35
	alignOrientation.MaxTorque = maxTorque
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.RigidityEnabled = false
	alignOrientation.PrimaryAxisOnly = false
	alignOrientation.Parent = rootPart

	return {
		RootPart = rootPart,
		TargetRoot = targetRoot,
		ObjectAttachment = objectAttachment,
		AnchorPart = anchorPart,
		AnchorAttachment = anchorAttachment,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
		RuntimeFolder = runtimeFolder,
		CollisionConstraints = {},
	}
end

function PhysicsPickupUtil.CreateNoCollisionConstraints(
	targetRoot: InteractableRoot,
	character: Model,
	parent: Instance
): { NoCollisionConstraint }
	local constraints = {}
	local heldParts = PhysicsPickupUtil.GetBaseParts(targetRoot)
	local characterParts = {}

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(characterParts, descendant)
		end
	end

	for _, heldPart in heldParts do
		for _, characterPart in characterParts do
			local noCollisionConstraint = Instance.new("NoCollisionConstraint")
			noCollisionConstraint.Part0 = heldPart
			noCollisionConstraint.Part1 = characterPart
			noCollisionConstraint.Parent = parent
			table.insert(constraints, noCollisionConstraint)
		end
	end

	return constraints
end

function PhysicsPickupUtil.CleanupHoldConstraints(bundle: HoldConstraintBundle)
	if bundle.AlignPosition.Parent then
		bundle.AlignPosition:Destroy()
	end
	if bundle.AlignOrientation.Parent then
		bundle.AlignOrientation:Destroy()
	end
	if bundle.ObjectAttachment.Parent then
		bundle.ObjectAttachment:Destroy()
	end
	if bundle.AnchorPart.Parent then
		bundle.AnchorPart:Destroy()
	end
	if bundle.RuntimeFolder.Parent then
		bundle.RuntimeFolder:Destroy()
	end
end

return PhysicsPickupUtil
