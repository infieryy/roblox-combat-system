--!strict
--[[
    GeometryUtil
    ------------
    Shared geometry helpers ported verbatim from the consensus PickupServer.
    Having ONE copy here means client (DragController/InteractionController)
    and server (DragService) both use identical pivot-correction logic — the
    duplication bug present in the consensus build is eliminated.
]]

local Config = require(script.Parent.Config)

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

-- The single BasePart the constraints attach to and whose network ownership is
-- transferred. Prefers an explicit PrimaryPart, otherwise the largest part by
-- volume — a stable default for Blender models with no PrimaryPart set.
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
            (target :: Model).PrimaryPart = best
        end
        return best
    end
    return nil
end

-- World-space bounding box (centreframe, size). Uses Model:GetBoundingBox()
-- which is computed from actual visual geometry, making it Blender-pivot immune.
function GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
    if target:IsA("Model") then
        return (target :: Model):GetBoundingBox()
    elseif target:IsA("BasePart") then
        local bp = target :: BasePart
        return bp.CFrame, bp.Size
    end
    return CFrame.identity, Vector3.zero
end

-- Dynamic Blender pivot correction: returns the world-space point the object
-- should be *carried by*. If the model's pivot is near the bounding-box centre
-- (i.e. it was set correctly in Blender) we honour the pivot; if the pivot
-- sits far from the visual centre — the classic import artefact — we snap to
-- the bounding-box centre so the mesh hovers centred, not offset.
function GeometryUtil.getVisualCenter(target: Instance): Vector3
    if target:IsA("BasePart") then
        return (target :: BasePart).Position
    end
    if target:IsA("Model") then
        local model = target :: Model
        local pivot = model:GetPivot()
        local boxCFrame, boxSize = model:GetBoundingBox()
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

-- Half-diagonal of the bounding box, used to adjust distance checks so large
-- objects are not rejected because only their centre is measured.
function GeometryUtil.getBoundingRadius(target: Instance): number
    local _, size = GeometryUtil.getBoundingBox(target)
    return size.Magnitude * 0.5
end

-- Largest single axis extent — used by the client to push large objects farther
-- away so they don't clip into the camera.
function GeometryUtil.getLargestAxis(target: Instance): number
    local _, size = GeometryUtil.getBoundingBox(target)
    return math.max(size.X, size.Y, size.Z)
end

-- Dynamic hold distance: base + size padding, clamped to [min, max].
function GeometryUtil.computeHoldDistance(target: Instance): number
    local dist = Config.Drag.holdDistanceBase
        + GeometryUtil.getLargestAxis(target) * Config.Drag.holdDistancePadding
    return math.clamp(dist, Config.Drag.holdDistanceMin, Config.Drag.holdDistanceMax)
end

return GeometryUtil
