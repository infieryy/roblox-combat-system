--!strict
-- Module: shared/GeometryUtil
-- Blender-import-friendly geometry helpers, PORTED VERBATIM from the consensus
-- PickupServer (BLUEPRINT.md §6, §9.1). A single copy now lives here and is
-- required by both the server (DragService) and the client (Interaction/Drag),
-- which removes the duplication the consensus build had.

local Config = require(script.Parent.Config)

local GeometryUtil = {}

-- Every BasePart that makes up an instance (the part itself, or all parts of a
-- Model).
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
-- transferred. Prefers an explicit PrimaryPart, otherwise the largest part by
-- volume (a robust, stable default for Blender models with no PrimaryPart).
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

-- World-space bounding box (centre CFrame, size). Uses Model:GetBoundingBox(),
-- computed from the actual visual geometry, so it is immune to a mis-placed
-- Blender pivot.
function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- DYNAMIC bounding-box pivot correction: returns the world-space point the
-- object should be carried by. For a model we normally use the bounding-box
-- centre, but if the pivot is close to that centre we trust the pivot (it may be
-- a deliberate handle). When the pivot is far from the visual centre -- the
-- classic Blender import artefact -- we snap to the bounding-box centre so the
-- mesh hovers centred, not offset.
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

-- Largest single axis of the bounding box (used for client hold framing).
function GeometryUtil.getLargestAxis(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return math.max(size.X, size.Y, size.Z)
end

return GeometryUtil
