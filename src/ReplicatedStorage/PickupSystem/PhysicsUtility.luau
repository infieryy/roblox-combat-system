--!strict

--[[
	Reusable physics helpers for Blender-imported models with irregular pivots.
	Handles bounding-box pivot correction, constraint setup, and collision isolation.
]]

local PhysicsService = game:GetService("PhysicsService")

local PhysicsUtility = {}

export type PickupModelInfo = {
	model: Model,
	rootPart: BasePart,
	pivotWorldCFrame: CFrame,
	pivotOffsetFromRoot: CFrame,
}

export type HoldConstraintSet = {
	objectAttachment: Attachment,
	holdAttachment: Attachment,
	alignPosition: AlignPosition,
	alignOrientation: AlignOrientation,
	noCollisionConstraints: { NoCollisionConstraint },
}

local function isPickupPart(instance: Instance): boolean
	return instance:IsA("BasePart") or instance:IsA("MeshPart")
end

local function getModelFromInstance(instance: Instance): Model?
	if instance:IsA("Model") then
		return instance
	end

	local ancestor = instance:FindFirstAncestorOfClass("Model")
	if ancestor and ancestor ~= workspace then
		return ancestor
	end

	return nil
end

--[[
	Returns the part that should drive physics for a pickup target.
	Prefers PrimaryPart, then the largest volume part (common for Blender imports).
]]
function PhysicsUtility.getRootPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local largestPart: BasePart? = nil
	local largestVolume = 0

	for _, descendant in model:GetDescendants() do
		if isPickupPart(descendant) then
			local part = descendant :: BasePart
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > largestVolume then
				largestVolume = volume
				largestPart = part
			end
		end
	end

	if largestPart then
		model.PrimaryPart = largestPart
	end

	return largestPart
end

--[[
	Computes a stable world-space pivot using the model bounding box center.
	Blender imports often have pivots far from visual mass; this corrects hold offsets.
]]
function PhysicsUtility.getModelPivotInfo(model: Model): PickupModelInfo?
	local rootPart = PhysicsUtility.getRootPart(model)
	if not rootPart then
		return nil
	end

	local pivotWorldCFrame: CFrame
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)

	if ok and pivot then
		pivotWorldCFrame = pivot
	else
		local boundsCFrame, _boundsSize = model:GetBoundingBox()
		pivotWorldCFrame = boundsCFrame
	end

	local pivotOffsetFromRoot = rootPart.CFrame:ToObjectSpace(pivotWorldCFrame)

	return {
		model = model,
		rootPart = rootPart,
		pivotWorldCFrame = pivotWorldCFrame,
		pivotOffsetFromRoot = pivotOffsetFromRoot,
	}
end

function PhysicsUtility.resolvePickupModel(instance: Instance, allowWrap: boolean?): Model?
	local model = getModelFromInstance(instance)
	if model then
		return model
	end

	if allowWrap == true and isPickupPart(instance) then
		local wrapper = Instance.new("Model")
		wrapper.Name = instance.Name .. "_Pickup"
		instance.Parent = wrapper
		wrapper.PrimaryPart = instance :: BasePart
		wrapper.Parent = workspace
		return wrapper
	end

	return nil
end

function PhysicsUtility.prepareModelForPickup(model: Model): PickupModelInfo?
	local info = PhysicsUtility.getModelPivotInfo(model)
	if not info then
		return nil
	end

	for _, descendant in model:GetDescendants() do
		if isPickupPart(descendant) then
			local part = descendant :: BasePart
			part.Anchored = false
			part.CanQuery = true
			part.CanTouch = true
		end
	end

	if not model.PrimaryPart then
		model.PrimaryPart = info.rootPart
	end

	return info
end

function PhysicsUtility.ensureCollisionGroups(heldGroupName: string, characterGroupName: string)
	local function register(name: string)
		local ok = pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
		if not ok then
			-- Group already exists in a live session hot-reload.
		end
	end

	register(heldGroupName)
	register(characterGroupName)

	PhysicsService:CollisionGroupSetCollidable(heldGroupName, characterGroupName, false)
	PhysicsService:CollisionGroupSetCollidable(heldGroupName, heldGroupName, true)
	PhysicsService:CollisionGroupSetCollidable(heldGroupName, "Default", true)
end

function PhysicsUtility.setModelCollisionGroup(model: Model, groupName: string)
	for _, descendant in model:GetDescendants() do
		if isPickupPart(descendant) then
			(descendant :: BasePart).CollisionGroup = groupName
		end
	end
end

function PhysicsUtility.setCharacterCollisionGroup(character: Model, groupName: string)
	for _, descendant in character:GetDescendants() do
		if isPickupPart(descendant) then
			(descendant :: BasePart).CollisionGroup = groupName
		end
	end
end

function PhysicsUtility.createNoCollisionWithCharacter(model: Model, character: Model): { NoCollisionConstraint }
	local constraints: { NoCollisionConstraint } = {}

	for _, modelDescendant in model:GetDescendants() do
		if not isPickupPart(modelDescendant) then
			continue
		end

		local objectPart = modelDescendant :: BasePart

		for _, characterDescendant in character:GetDescendants() do
			if not isPickupPart(characterDescendant) then
				continue
			end

			local characterPart = characterDescendant :: BasePart
			local noCollision = Instance.new("NoCollisionConstraint")
			noCollision.Part0 = objectPart
			noCollision.Part1 = characterPart
			noCollision.Parent = objectPart
			table.insert(constraints, noCollision)
		end
	end

	return constraints
end

function PhysicsUtility.createHoldConstraints(
	modelInfo: PickupModelInfo,
	holdPart: BasePart,
	alignPositionResponsiveness: number,
	alignPositionMaxForce: number,
	alignPositionMaxVelocity: number,
	alignOrientationResponsiveness: number,
	alignOrientationMaxTorque: number,
	alignOrientationMaxAngularVelocity: number
): HoldConstraintSet
	local rootPart = modelInfo.rootPart

	local objectAttachment = Instance.new("Attachment")
	objectAttachment.Name = "PickupObjectAttachment"
	objectAttachment.CFrame = modelInfo.pivotOffsetFromRoot
	objectAttachment.Parent = rootPart

	local holdAttachment = Instance.new("Attachment")
	holdAttachment.Name = "PickupHoldAttachment"
	holdAttachment.Parent = holdPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupAlignPosition"
	alignPosition.Attachment0 = objectAttachment
	alignPosition.Attachment1 = holdAttachment
	alignPosition.RigidityEnabled = false
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ReactionForceEnabled = false
	alignPosition.Responsiveness = alignPositionResponsiveness
	alignPosition.MaxForce = alignPositionMaxForce
	alignPosition.MaxVelocity = alignPositionMaxVelocity
	alignPosition.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupAlignOrientation"
	alignOrientation.Attachment0 = objectAttachment
	alignOrientation.Attachment1 = holdAttachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.Responsiveness = alignOrientationResponsiveness
	alignOrientation.MaxTorque = alignOrientationMaxTorque
	alignOrientation.MaxAngularVelocity = alignOrientationMaxAngularVelocity
	alignOrientation.Parent = rootPart

	return {
		objectAttachment = objectAttachment,
		holdAttachment = holdAttachment,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
		noCollisionConstraints = {},
	}
end

function PhysicsUtility.destroyHoldConstraints(constraintSet: HoldConstraintSet)
	for _, constraint in constraintSet.noCollisionConstraints do
		constraint:Destroy()
	end

	constraintSet.alignOrientation:Destroy()
	constraintSet.alignPosition:Destroy()
	constraintSet.holdAttachment:Destroy()
	constraintSet.objectAttachment:Destroy()
end

function PhysicsUtility.createHoldPart(character: Model): BasePart?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return nil
	end

	local holdPart = Instance.new("Part")
	holdPart.Name = "PickupHoldTarget"
	holdPart.Size = Vector3.new(0.2, 0.2, 0.2)
	holdPart.Transparency = 1
	holdPart.CanCollide = false
	holdPart.CanQuery = false
	holdPart.CanTouch = false
	holdPart.Massless = true
	holdPart.Anchored = true
	holdPart.CFrame = rootPart.CFrame
	holdPart.Parent = character

	return holdPart
end

return PhysicsUtility
