--!strict
-- Module: GeometryUtil
-- Geometry helpers ported verbatim from the consensus PickupServer, de-duplicated.
-- Previously each of the two consensus scripts had its own copy; this single module
-- is required by DragService (server) and InteractionController/DragController (client).
--
-- Every function is immune to the Blender off-centre pivot artefact.

local Config = require(script.Parent.Config)
local Workspace = game:GetService("Workspace")

local GeometryUtil = {}

-- Every BasePart that makes up an instance (the part itself, or all parts of a Model).
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

-- The single BasePart the constraints attach to.
-- Prefers an explicit PrimaryPart; otherwise the largest part by volume.
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

-- World-space bounding box (centre CFrame, size).
-- Uses Model:GetBoundingBox() which is computed from visual geometry,
-- making it immune to a mis-placed Blender pivot.
function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- Returns the world-space point the object should be *carried by*.
-- For models: uses the bounding-box centre unless the pivot is already close to it
-- (a deliberate handle), in which case the pivot is trusted.
-- This is the core fix for Blender imports with off-centre pivots.
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

-- Half-diagonal of the bounding box (used for hold-distance framing and leash math).
function GeometryUtil.getBoundingRadius(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return size.Magnitude * 0.5
end

-- Largest single axis of the bounding box (used for hold-distance framing on client).
function GeometryUtil.getLargestAxis(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return math.max(size.X, size.Y, size.Z)
end

-- Compute how far in front of the camera a held object should float.
-- Scales with the object's footprint so large meshes are pushed back to stay in frame.
function GeometryUtil.computeHoldDistance(target: Instance): number
	local distance = Config.Drag.holdDistanceBase + GeometryUtil.getLargestAxis(target) * Config.Drag.holdDistancePadding
	return math.clamp(distance, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

return GeometryUtil
