--!strict
-- Module: GeometryUtil
-- Geometry helpers shared between server (DragService) and client (InteractionController,
-- DragController). Ported verbatim from the consensus PickupServer build — removes the
-- duplication that existed between the two consensus scripts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local GeometryUtil = {}

-- Every BasePart that composes an instance (the part itself or all parts of a Model).
function GeometryUtil.getParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
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

-- The single BasePart the constraints attach to and whose network ownership is
-- transferred. Prefers an explicit PrimaryPart; otherwise falls back to the
-- largest part by volume (stable default for Blender models with no PrimaryPart).
function GeometryUtil.getPrimaryPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if target:IsA("Model") then
		if target.PrimaryPart then
			return target.PrimaryPart
		end
		local best: BasePart? = nil
		local bestVolume = -1
		for _, part in GeometryUtil.getParts(target) do
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			if volume > bestVolume then
				bestVolume = volume
				best = part
			end
		end
		if best then
			target.PrimaryPart = best
		end
		return best
	end
	return nil
end

-- World-space bounding box (centre CFrame, size). Uses Model:GetBoundingBox() which
-- is computed from actual visual geometry — immune to a mis-placed Blender pivot.
function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- Dynamic bounding-box pivot correction (the Blender fix from the consensus build).
-- Returns the world-space point the object should be *carried by*.
-- If the pivot sits close to the bbox centre we trust it (deliberate handle).
-- If it's far away (classic Blender import artefact) we snap to the bbox centre
-- so the mesh hovers centred rather than offset.
function GeometryUtil.getVisualCenter(target: Instance): Vector3
	if target:IsA("BasePart") then
		return target.Position
	end
	if target:IsA("Model") then
		local pivot = target:GetPivot()
		local boxCFrame, boxSize = target:GetBoundingBox()
		local diagonal = boxSize.Magnitude
		if diagonal > 0 then
			local offsetRatio = (pivot.Position - boxCFrame.Position).Magnitude / diagonal
			if offsetRatio <= Config.Drag.pivotCorrectionThreshold then
				return pivot.Position
			end
		end
		return boxCFrame.Position
	end
	return Vector3.zero
end

function GeometryUtil.getBoundingRadius(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return size.Magnitude * 0.5
end

-- Largest single axis of the bounding box — used to compute hold distance so
-- large objects are automatically pushed further back to stay in-frame.
function GeometryUtil.getLargestAxis(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return math.max(size.X, size.Y, size.Z)
end

-- Compute the hold distance (studs in front of camera) for a given object,
-- clamped by the configured min/max.
function GeometryUtil.computeHoldDistance(target: Instance): number
	local dist = Config.Drag.holdDistanceBase + GeometryUtil.getLargestAxis(target) * Config.Drag.holdDistancePadding
	return math.clamp(dist, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

return GeometryUtil
