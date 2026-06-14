--!strict

local CollectionService = game:GetService("CollectionService")

local PhysicsUtil = {}

export type HoldRig = {
	target: Instance,
	rootPart: BasePart,
	parts: { BasePart },
	anchorPart: Part,
	anchorAttachment: Attachment,
	objectAttachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	noCollisionConstraints: { NoCollisionConstraint },
	tempWelds: { WeldConstraint },
	originalAnchored: { [BasePart]: boolean },
}

local ANCHOR_FOLDER_NAME = "_PickupAnchors"
local INTERACTABLE_TAG = "Interactable"
local INTERACTABLE_ATTRIBUTE = "Interactable"

local function getOrCreateAnchorFolder(): Folder
	local folder = workspace:FindFirstChild(ANCHOR_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = ANCHOR_FOLDER_NAME
	newFolder.Parent = workspace
	return newFolder
end

function PhysicsUtil.isInteractable(instance: Instance?): boolean
	if instance == nil then
		return false
	end

	return CollectionService:HasTag(instance, INTERACTABLE_TAG) or instance:GetAttribute(INTERACTABLE_ATTRIBUTE) == true
end

function PhysicsUtil.resolveInteractableRoot(instance: Instance?): Instance?
	local cursor = instance
	while cursor ~= nil do
		if PhysicsUtil.isInteractable(cursor) and (cursor:IsA("Model") or cursor:IsA("BasePart")) then
			return cursor
		end
		cursor = cursor.Parent
	end

	return nil
end

function PhysicsUtil.getAssemblyParts(target: Instance): { BasePart }
	if target:IsA("BasePart") then
		return { target }
	end

	if target:IsA("Model") then
		local parts = {}
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
			end
		end
		return parts
	end

	return {}
end

local function chooseClosestPartToPosition(parts: { BasePart }, targetPosition: Vector3): BasePart?
	local closestPart: BasePart? = nil
	local closestDistance = math.huge

	for _, part in parts do
		local distance = (part.Position - targetPosition).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestPart = part
		end
	end

	return closestPart
end

function PhysicsUtil.getRootPartAndPivot(target: Instance): (BasePart?, CFrame?)
	if target:IsA("BasePart") then
		return target, target.CFrame
	end

	if target:IsA("Model") then
		local parts = PhysicsUtil.getAssemblyParts(target)
		if #parts == 0 then
			return nil, nil
		end

		local pivotCFrame = target:GetPivot()
		local boundingBox = target:GetBoundingBox()
		local primary = target.PrimaryPart or chooseClosestPartToPosition(parts, boundingBox.Position)
		return primary, pivotCFrame
	end

	return nil, nil
end

function PhysicsUtil.computeCenterAttachmentCFrame(rootPart: BasePart, target: Instance): CFrame
	if target:IsA("BasePart") then
		return CFrame.identity
	end

	if target:IsA("Model") then
		local pivot = target:GetPivot()
		local boundingBox = target:GetBoundingBox()
		-- Use the model's rotation with bounding box center to mitigate Blender pivot offsets.
		local centerFrame = CFrame.fromMatrix(
			boundingBox.Position,
			pivot.XVector,
			pivot.YVector,
			pivot.ZVector
		)
		return rootPart.CFrame:ToObjectSpace(centerFrame)
	end

	return CFrame.identity
end

local function createTemporaryWelds(rootPart: BasePart, parts: { BasePart }): { WeldConstraint }
	local welds = {}
	for _, part in parts do
		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupTempWeld"
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
			table.insert(welds, weld)
		end
	end
	return welds
end

local function collectCharacterParts(character: Model): { BasePart }
	local characterParts = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(characterParts, descendant)
		end
	end
	return characterParts
end

local function createNoCollisionConstraints(heldParts: { BasePart }, character: Model): { NoCollisionConstraint }
	local noCollisionConstraints = {}
	local characterParts = collectCharacterParts(character)

	for _, heldPart in heldParts do
		for _, characterPart in characterParts do
			local noCollision = Instance.new("NoCollisionConstraint")
			noCollision.Name = "PickupNoCollision"
			noCollision.Part0 = heldPart
			noCollision.Part1 = characterPart
			noCollision.Parent = heldPart
			table.insert(noCollisionConstraints, noCollision)
		end
	end

	return noCollisionConstraints
end

function PhysicsUtil.createHoldRig(player: Player, target: Instance, character: Model): HoldRig?
	local rootPart, _ = PhysicsUtil.getRootPartAndPivot(target)
	if rootPart == nil then
		return nil
	end

	local parts = PhysicsUtil.getAssemblyParts(target)
	if #parts == 0 then
		return nil
	end

	local originalAnchored: { [BasePart]: boolean } = {}
	for _, part in parts do
		originalAnchored[part] = part.Anchored
		part.Anchored = false
	end

	local tempWelds = createTemporaryWelds(rootPart, parts)
	local noCollisionConstraints = createNoCollisionConstraints(parts, character)

	local anchorFolder = getOrCreateAnchorFolder()
	local anchorPart = Instance.new("Part")
	anchorPart.Name = (`{player.UserId}_HoldAnchor`)
	anchorPart.Size = Vector3.new(0.2, 0.2, 0.2)
	anchorPart.Transparency = 1
	anchorPart.Anchored = true
	anchorPart.CanCollide = false
	anchorPart.CanQuery = false
	anchorPart.CanTouch = false
	anchorPart.Parent = anchorFolder

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "HoldTargetAttachment"
	anchorAttachment.Parent = anchorPart

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "HoldObjectAttachment"
	objectAttachment.CFrame = PhysicsUtil.computeCenterAttachmentCFrame(rootPart, target)
	objectAttachment.Parent = rootPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "HoldAlignPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = anchorAttachment
	alignPosition.ReactionForceEnabled = false
	alignPosition.MaxForce = 1_000_000
	alignPosition.MaxVelocity = 80
	alignPosition.Responsiveness = 35
	alignPosition.RigidityEnabled = false
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "HoldAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = anchorAttachment
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = 1_000_000
	alignOrientation.Responsiveness = 30
	alignOrientation.RigidityEnabled = false
	alignOrientation.Parent = rootPart

	rootPart:SetNetworkOwner(player)

	return {
		target = target,
		rootPart = rootPart,
		parts = parts,
		anchorPart = anchorPart,
		anchorAttachment = anchorAttachment,
		objectAttachment = objectAttachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		noCollisionConstraints = noCollisionConstraints,
		tempWelds = tempWelds,
		originalAnchored = originalAnchored,
	}
end

function PhysicsUtil.updateHoldTarget(rig: HoldRig, targetCFrame: CFrame)
	rig.anchorPart.CFrame = targetCFrame
end

local function safeDestroy(instance: Instance?)
	if instance ~= nil and instance.Parent ~= nil then
		instance:Destroy()
	end
end

function PhysicsUtil.destroyHoldRig(rig: HoldRig)
	for _, noCollision in rig.noCollisionConstraints do
		safeDestroy(noCollision)
	end

	for _, weld in rig.tempWelds do
		safeDestroy(weld)
	end

	for _, part in rig.parts do
		local originalAnchored = rig.originalAnchored[part]
		if originalAnchored ~= nil then
			part.Anchored = originalAnchored
		end
	end

	if rig.rootPart.Parent ~= nil then
		rig.rootPart:SetNetworkOwnershipAuto()
	end

	safeDestroy(rig.alignPosition)
	safeDestroy(rig.alignOrientation)
	safeDestroy(rig.objectAttachment)
	safeDestroy(rig.anchorPart)
end

return PhysicsUtil
