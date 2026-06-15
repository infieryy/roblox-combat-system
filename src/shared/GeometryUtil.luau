--!strict
--[[
	GeometryUtil  (shared/GeometryUtil.luau → ReplicatedStorage.Shared.GeometryUtil)
	----------------------------------------------------------------------------------
	Geometry and mass utilities shared by DragService (server) and the interaction/
	drag controllers (client). Ported from the consensus PickupServer — one canonical
	copy replaces the duplicated helpers that existed in each monolithic script.

	Handles the main Blender-import quirks:
	  • Models may have no PrimaryPart set.
	  • MeshParts frequently have off-centre pivots.
	  • Visual centre and centre of mass rarely coincide.
]]

local Config = require(script.Parent.Config)

local GeometryUtil = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Part collection
-- ─────────────────────────────────────────────────────────────────────────────

-- All BaseParts that make up an instance (itself if it is a part, plus all
-- descendant parts for Models).
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Primary part resolution
-- ─────────────────────────────────────────────────────────────────────────────

-- The single BasePart the drag rig attaches to and whose network ownership is
-- transferred. Prefers an explicit PrimaryPart; falls back to the largest part
-- by volume — a robust default for Blender models that have no PrimaryPart.
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
		-- Cache the result so subsequent calls are O(1).
		if best and target:IsA("Model") then
			(target :: Model).PrimaryPart = best
		end
		return best
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bounding box
-- ─────────────────────────────────────────────────────────────────────────────

-- World-space bounding box (centre CFrame, size vector). Uses
-- Model:GetBoundingBox() which is computed from actual visual geometry, so it
-- is correct even when a Blender mesh has a mis-placed pivot.
function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	end
	if target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

-- Half the bounding-box diagonal: a single "radius" value used to scale hold
-- distances and leash radii for large objects.
function GeometryUtil.getBoundingRadius(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return size.Magnitude * 0.5
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Visual centre (Blender pivot correction)
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the world-space point the object should be *carried by*.
-- For a model we normally use the bounding-box centre. However, if the pivot
-- is close to the visual centre we trust the pivot instead — it may be a
-- deliberate handle point. When the pivot is far from the visual centre (the
-- classic Blender import artefact) we snap to the bounding-box centre so the
-- mesh floats centred, not offset.
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Hold distance
-- ─────────────────────────────────────────────────────────────────────────────

-- How far in front of the camera the object should float while being dragged,
-- scaled to its size so large props are pushed back to stay fully in frame.
function GeometryUtil.getHoldDistance(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	local largestAxis = math.max(size.X, size.Y, size.Z)
	local dist = Config.Drag.holdDistanceBase + largestAxis * Config.Drag.holdDistancePadding
	return math.clamp(dist, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

return GeometryUtil
