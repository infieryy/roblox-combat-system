--!strict
--[[
	PhysicsUtility
	Reusable helpers for interactable detection, Blender pivot correction,
	constraint setup, and collision-group management.
]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupConfig = require(ReplicatedStorage.Shared.PickupConfig)

export type InteractableRoot = Model | BasePart
export type HoldConstraintSet = {
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	objectAttachment: Attachment,
	holdAttachment: Attachment,
	rootPart: BasePart,
}

local PhysicsUtility = {}

local collisionGroupsRegistered = false

local function getBoundingDiagonal(size: Vector3): number
	return size.Magnitude
end

function PhysicsUtility.ensureCollisionGroups(): ()
	if collisionGroupsRegistered then
		return
	end

	local playerGroup = PickupConfig.COLLISION_GROUP_PLAYER
	local heldGroup = PickupConfig.COLLISION_GROUP_HELD
	local defaultGroup = PickupConfig.COLLISION_GROUP_DEFAULT

	if not PhysicsService:IsCollisionGroupRegistered(playerGroup) then
		PhysicsService:RegisterCollisionGroup(playerGroup)
	end
	if not PhysicsService:IsCollisionGroupRegistered(heldGroup) then
		PhysicsService:RegisterCollisionGroup(heldGroup)
	end

	PhysicsService:CollisionGroupSetCollidable(heldGroup, playerGroup, false)
	PhysicsService:CollisionGroupSetCollidable(heldGroup, heldGroup, true)
	PhysicsService:CollisionGroupSetCollidable(heldGroup, defaultGroup, true)

	collisionGroupsRegistered = true
end

function PhysicsUtility.setCharacterCollisionGroup(character: Model): ()
	PhysicsUtility.ensureCollisionGroups()
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = PickupConfig.COLLISION_GROUP_PLAYER
		end
	end
end

function PhysicsUtility.setHeldCollisionGroup(root: InteractableRoot): ()
	PhysicsUtility.ensureCollisionGroups()
	local parts = PhysicsUtility.getAllBaseParts(root)
	for _, part in parts do
		part.CollisionGroup = PickupConfig.COLLISION_GROUP_HELD
	end
end

function PhysicsUtility.restoreDefaultCollisionGroup(root: InteractableRoot): ()
	local parts = PhysicsUtility.getAllBaseParts(root)
	for _, part in parts do
		part.CollisionGroup = PickupConfig.COLLISION_GROUP_DEFAULT
	end
end

function PhysicsUtility.getAllBaseParts(root: InteractableRoot): { BasePart }
	local parts: { BasePart } = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
		return parts
	end

	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	local primaryPart = (root :: Model).PrimaryPart
	if primaryPart and not table.find(parts, primaryPart) then
		table.insert(parts, primaryPart)
	end

	return parts
end

function PhysicsUtility.isInteractable(instance: Instance): boolean
	if instance:GetAttribute(PickupConfig.INTERACT_ATTRIBUTE) == true then
		return true
	end
	if CollectionService:HasTag(instance, PickupConfig.INTERACT_TAG) then
		return true
	end
	return false
end

function PhysicsUtility.getInteractableRoot(instance: Instance): InteractableRoot?
	local current: Instance? = instance
	while current do
		if current:IsA("Model") or current:IsA("BasePart") then
			if PhysicsUtility.isInteractable(current) then
				return current :: InteractableRoot
			end
		end
		current = current.Parent
	end
	return nil
end

function PhysicsUtility.getModelBoundingBox(model: Model): (CFrame, Vector3)
	return model:GetBoundingBox()
end

function PhysicsUtility.getObjectWorldPosition(root: InteractableRoot): Vector3
	if root:IsA("BasePart") then
		return root.Position
	end

	local model = root :: Model
	local bboxCFrame = select(1, model:GetBoundingBox())
	return bboxCFrame.Position
end

--[[
	Returns the world-space CFrame where hold forces should be applied.
	Automatically corrects Blender imports whose pivot sits far from the visual center.
]]
function PhysicsUtility.getHoldAnchorCFrame(root: InteractableRoot): CFrame
	if root:IsA("BasePart") then
		return root.CFrame
	end

	local model = root :: Model
	local pivot = model:GetPivot()
	local bboxCFrame, bboxSize = model:GetBoundingBox()

	if model:GetAttribute("UseBoundingCenter") == true then
		return CFrame.new(bboxCFrame.Position) * pivot.Rotation
	end

	local diagonal = getBoundingDiagonal(bboxSize)
	if diagonal <= 0 then
		return pivot
	end

	local pivotToCenter = pivot.Position - bboxCFrame.Position
	local offsetRatio = pivotToCenter.Magnitude / diagonal

	if offsetRatio > PickupConfig.PIVOT_CORRECTION_THRESHOLD then
		return CFrame.new(bboxCFrame.Position) * pivot.Rotation
	end

	return pivot
end

function PhysicsUtility.getRootPart(root: InteractableRoot): BasePart?
	if root:IsA("BasePart") then
		return root
	end

	local model = root :: Model
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local largestPart: BasePart? = nil
	local largestVolume = 0

	for _, part in PhysicsUtility.getAllBaseParts(model) do
		local volume = part.Size.X * part.Size.Y * part.Size.Z
		if volume > largestVolume then
			largestVolume = volume
			largestPart = part
		end
	end

	if largestPart then
		model.PrimaryPart = largestPart
	end

	return largestPart
end

function PhysicsUtility.prepareForPickup(root: InteractableRoot): BasePart
	local rootPart = PhysicsUtility.getRootPart(root)
	if not rootPart then
		error(`[PhysicsUtility] Interactable {root:GetFullName()} has no BasePart`)
	end

	for _, part in PhysicsUtility.getAllBaseParts(root) do
		part.Anchored = false
		part.CanTouch = true
	end

	return rootPart
end

function PhysicsUtility.createHoldConstraints(
	rootPart: BasePart,
	holdTarget: BasePart,
	holdAnchorCFrame: CFrame
): HoldConstraintSet
	local existing = rootPart:FindFirstChild("PickupAlignPosition")
	if existing then
		existing:Destroy()
	end

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "PickupObjectAttachment"
	local localOffset = rootPart.CFrame:ToObjectSpace(holdAnchorCFrame)
	objectAttachment.CFrame = localOffset
	objectAttachment.Parent = rootPart

	local holdAttachment = Instance.new("Attachment")
	holdAttachment.Name = "PickupHoldAttachment"
	holdAttachment.Parent = holdTarget

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = holdAttachment
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = PickupConfig.ALIGN_MAX_FORCE
	alignPosition.MaxVelocity = PickupConfig.ALIGN_MAX_VELOCITY
	alignPosition.Responsiveness = PickupConfig.ALIGN_RESPONSIVENESS
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ReactionForceEnabled = false
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = holdAttachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = PickupConfig.ORIENT_MAX_TORQUE
	alignOrientation.MaxAngularVelocity = PickupConfig.ORIENT_MAX_ANGULAR_VELOCITY
	alignOrientation.Responsiveness = PickupConfig.ORIENT_RESPONSIVENESS
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.Parent = rootPart

	return {
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		objectAttachment = objectAttachment,
		holdAttachment = holdAttachment,
		rootPart = rootPart,
	}
end

function PhysicsUtility.destroyHoldConstraints(constraintSet: HoldConstraintSet): ()
	constraintSet.alignPosition:Destroy()
	constraintSet.alignOrientation:Destroy()
	constraintSet.objectAttachment:Destroy()
	constraintSet.holdAttachment:Destroy()
end

function PhysicsUtility.createHoldTarget(player: Player): BasePart
	local holdTarget = Instance.new("Part")
	holdTarget.Name = PickupConfig.HOLD_TARGET_NAME
	holdTarget.Size = Vector3.new(0.2, 0.2, 0.2)
	holdTarget.Transparency = 1
	holdTarget.CanCollide = false
	holdTarget.CanQuery = false
	holdTarget.CanTouch = false
	holdTarget.Anchored = false
	holdTarget.Massless = true
	holdTarget.CastShadow = false
	holdTarget.CFrame = CFrame.new(0, 5, 0)
	holdTarget:SetAttribute("OwnerUserId", player.UserId)
	holdTarget.Parent = workspace

	return holdTarget
end

function PhysicsUtility.setNetworkOwnership(root: InteractableRoot, player: Player?): ()
	local parts = PhysicsUtility.getAllBaseParts(root)
	for _, part in parts do
		if player then
			part:SetNetworkOwner(player)
		else
			part:SetNetworkOwnershipAuto()
		end
	end
end

function PhysicsUtility.buildRaycastParams(character: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	local filterList: { Instance } = {}
	if character then
		table.insert(filterList, character)
	end

	local holdTargets = workspace:GetChildren()
	for _, child in holdTargets do
		if child:IsA("BasePart") and child.Name == PickupConfig.HOLD_TARGET_NAME then
			table.insert(filterList, child)
		end
	end

	params.FilterDescendantsInstances = filterList
	return params
end

return PhysicsUtility
