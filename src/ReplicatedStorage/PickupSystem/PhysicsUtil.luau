--!strict
--[[
	PhysicsUtil
	-----------
	A pure, reusable physics helper module. It contains no game state and no
	RemoteEvent logic; it only knows how to reason about a grabbable instance
	(a `BasePart` or a `Model`) and how to build the modern constraint rig used
	to drag it around.

	Design notes:
	  * Modern constraints only (AlignPosition / AlignOrientation /
	    WeldConstraint / NoCollisionConstraint). No BodyPosition / BodyGyro.
	  * Blender-friendly: positions are derived from `Model:GetBoundingBox()`
	    rather than the (often off-centre) imported PrimaryPart pivot, and
	    `ApplyAtCenterOfMass` is enabled so an asymmetric centre of mass does
	    not induce parasitic spin while dragging.
	  * Everything this module creates is named with `PhysicsUtil.Prefix` so a
	    session can find and tear it down deterministically.
]]

local Config = require(script.Parent.Config)

local PhysicsUtil = {}

-- Shared naming so the server can build the rig and the client can locate it.
PhysicsUtil.Prefix = "PickupSystem_"
PhysicsUtil.AttachmentName = PhysicsUtil.Prefix .. "Attachment"
PhysicsUtil.AlignPositionName = PhysicsUtil.Prefix .. "AlignPosition"
PhysicsUtil.AlignOrientationName = PhysicsUtil.Prefix .. "AlignOrientation"

export type HoldRig = {
	Attachment: Attachment,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
}

--[[ Returns every BasePart belonging to the grabbable instance. ]]
function PhysicsUtil.getParts(object: Instance): { BasePart }
	local parts: { BasePart } = {}
	if object:IsA("BasePart") then
		table.insert(parts, object)
	end
	for _, descendant in ipairs(object:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--[[
	Resolves the single BasePart that the constraint rig should attach to.
	For a Model without an explicit PrimaryPart we fall back to the largest
	part (and remember it as the PrimaryPart) so the choice is stable.
]]
function PhysicsUtil.getHandle(object: Instance): BasePart?
	if object:IsA("BasePart") then
		return object
	end

	if object:IsA("Model") then
		if object.PrimaryPart then
			return object.PrimaryPart
		end

		local best: BasePart? = nil
		local bestVolume = -1
		for _, part in ipairs(PhysicsUtil.getParts(object)) do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > bestVolume then
				bestVolume = volume
				best = part
			end
		end

		if best then
			object.PrimaryPart = best
		end
		return best
	end

	return nil
end

--[[
	World-space bounding box of the object. Uses the engine's tight model box
	(which respects mesh geometry) so we never depend on the Blender pivot.
	Returns (centreCFrame, size).
]]
function PhysicsUtil.getBoundingBox(object: Instance): (CFrame, Vector3)
	if object:IsA("Model") then
		return object:GetBoundingBox()
	elseif object:IsA("BasePart") then
		return object.CFrame, object.Size
	end
	return CFrame.identity, Vector3.zero
end

--[[ Largest side of the bounding box; used to frame the object on screen. ]]
function PhysicsUtil.getLargestAxis(object: Instance): number
	local _, size = PhysicsUtil.getBoundingBox(object)
	return math.max(size.X, size.Y, size.Z)
end

--[[ Total mass of the welded assembly the handle belongs to. ]]
function PhysicsUtil.getAssemblyMass(handle: BasePart): number
	local mass = 0
	for _, part in ipairs(handle:GetConnectedParts(true)) do
		if not part.Massless then
			mass += part:GetMass()
		end
	end
	if mass <= 0 then
		mass = math.max(handle:GetMass(), 0.1)
	end
	return mass
end

--[[
	Guarantees the model behaves as one rigid assembly by welding any loose
	part to the handle. Returns the welds it created so the caller can undo
	them on drop and leave the asset exactly as it was found.
]]
function PhysicsUtil.ensureWelded(object: Instance, handle: BasePart): { WeldConstraint }
	local welds: { WeldConstraint } = {}
	if not object:IsA("Model") then
		return welds
	end

	local connected: { [BasePart]: boolean } = {}
	for _, part in ipairs(handle:GetConnectedParts(true)) do
		connected[part] = true
	end

	for _, part in ipairs(PhysicsUtil.getParts(object)) do
		if part ~= handle and not connected[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Name = PhysicsUtil.Prefix .. "Weld"
			weld.Part0 = handle
			weld.Part1 = part
			weld.Parent = handle
			table.insert(welds, weld)
		end
	end

	return welds
end

--[[
	Hands physics authority of the assembly to `player` (or back to the server
	when `player` is nil). Wrapped in pcall because SetNetworkOwner throws on
	anchored or non-network-owned assemblies. Returns success.
]]
function PhysicsUtil.setNetworkOwner(handle: BasePart, player: Player?): boolean
	local ok = pcall(function()
		if handle:IsGrounded() then
			-- Anchored / grounded assemblies cannot have an owner assigned.
			error("assembly is grounded")
		end
		if player then
			handle:SetNetworkOwner(player)
		else
			handle:SetNetworkOwnershipAuto()
		end
	end)
	return ok
end

--[[
	Builds the AlignPosition + AlignOrientation rig that drags the object.

	`centreWorld` is the bounding-box centre, which is where Attachment0 sits so
	that the *visible* centre of the mesh tracks the goal (independent of the
	Blender pivot). `ApplyAtCenterOfMass` makes the linear force act through the
	real centre of mass to avoid unwanted torque on lopsided imports.
]]
function PhysicsUtil.createHoldRig(handle: BasePart, centreWorld: Vector3, mass: number): HoldRig
	local attachment = Instance.new("Attachment")
	attachment.Name = PhysicsUtil.AttachmentName
	attachment.Position = handle.CFrame:PointToObjectSpace(centreWorld)
	attachment.Parent = handle

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = PhysicsUtil.AlignPositionName
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.ReactionForceEnabled = false
	alignPosition.RigidityEnabled = false
	alignPosition.MaxForce = math.max(Config.MinForce, mass * Config.ForcePerMass)
	alignPosition.MaxVelocity = Config.MaxVelocity
	alignPosition.Responsiveness = Config.PositionResponsiveness
	alignPosition.Position = centreWorld
	alignPosition.Parent = handle

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = PhysicsUtil.AlignOrientationName
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.ReactionTorqueEnabled = false
	alignOrientation.MaxTorque = math.max(Config.MinTorque, mass * Config.TorquePerMass)
	alignOrientation.MaxAngularVelocity = Config.MaxAngularVelocity
	alignOrientation.Responsiveness = Config.OrientationResponsiveness
	alignOrientation.CFrame = handle.CFrame.Rotation
	alignOrientation.Parent = handle

	return {
		Attachment = attachment,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
	}
end

--[[
	Disables collision between every part of the object and every part of the
	holder's own character using NoCollisionConstraints. Collisions against the
	rest of the world (walls, floors, other players) are untouched. Returns the
	constraints for later cleanup.
]]
function PhysicsUtil.disableCharacterCollisions(object: Instance, character: Model): { NoCollisionConstraint }
	local created: { NoCollisionConstraint } = {}
	local objectParts = PhysicsUtil.getParts(object)

	for _, characterPart in ipairs(character:GetDescendants()) do
		if characterPart:IsA("BasePart") then
			for _, objectPart in ipairs(objectParts) do
				local constraint = Instance.new("NoCollisionConstraint")
				constraint.Name = PhysicsUtil.Prefix .. "NoCollision"
				constraint.Part0 = objectPart
				constraint.Part1 = characterPart
				constraint.Parent = objectPart
				table.insert(created, constraint)
			end
		end
	end

	return created
end

--[[ Safely destroys a list of instances, ignoring already-removed ones. ]]
function PhysicsUtil.destroyAll(instances: { Instance }?)
	if not instances then
		return
	end
	for _, instance in ipairs(instances) do
		if instance and instance.Parent then
			instance:Destroy()
		end
	end
end

return PhysicsUtil
