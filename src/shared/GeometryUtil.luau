--!strict
-- Module: shared/GeometryUtil.luau
-- Ported from consensus PickupServer geometry helpers.

local Config = require(script.Parent.Config)

local GeometryUtil = {}

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

function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
	if target:IsA("Model") then
		return target:GetBoundingBox()
	elseif target:IsA("BasePart") then
		return target.CFrame, target.Size
	end
	return CFrame.identity, Vector3.zero
end

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

function GeometryUtil.getLargestAxis(target: Instance): number
	local _, size = GeometryUtil.getBoundingBox(target)
	return math.max(size.X, size.Y, size.Z)
end

function GeometryUtil.computeHoldDistance(target: Instance): number
	local distance = Config.Drag.holdDistanceBase + GeometryUtil.getLargestAxis(target) * Config.Drag.holdDistancePadding
	return math.clamp(distance, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

return GeometryUtil
