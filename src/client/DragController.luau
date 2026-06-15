--!strict
--[[
    DragController  (client)
    ------------------------
    Steers the server-built AlignPosition + AlignOrientation constraint rig.
    Ported from the consensus FirstPersonPickupClient with the following
    behavioural changes for the bridge build:

      • Grab is now initiated by InteractionController (not E key) when the
        player left-clicks on a draggable prop. Release ends the drag.
      • Orientation goal is set ONCE on DragGranted (grab-time world orientation)
        and never updated per frame — decision #2: position-only drag.
      • Inspect-rotate code path is present but gated by Config.Drag.enableInspect.
      • Mouse-wheel adjusts hold distance (ported).
      • Auto-releases if the server fires DragEnded or HoldStateChanged("None").

    Public API (called by InteractionController and init.client):
      beginDrag(prop)     — called when the player clicks on a prop
      endDrag()           — called when the player releases the mouse
      isDragging()        — predicate for WeaponController / InteractionController
      getSmoothedDelta()  — mouse-movement delta for ViewmodelController sway

    The FLING effect is emergent: because the client owns network physics while
    holding, the object retains its velocity from the AlignPosition constraint
    at the moment the rig is destroyed on the server. No extra impulse code
    needed client-side (the server applies a small DropImpulseSpeed nudge).
]]

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace      = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil") :: ModuleScript)

local RemotesClient = require(script.Parent.RemotesClient)

local localPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
type HoldData = {
    object:           Instance,
    primary:          BasePart,
    alignPosition:    AlignPosition,
    alignOrientation: AlignOrientation,
    holdDistance:     number,
    -- Grab-time world rotation (never changes — no rotation mode).
    fixedOrientGoal:  CFrame,
}

local hold: HoldData? = nil
local isDraggingFlag = false

-- Mouse-movement smoothing for ViewmodelController sway.
local rawDelta      = Vector2.zero
local smoothedDelta = Vector2.zero

local connections: { RBXScriptConnection } = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function getCamera(): Camera
    return Workspace.CurrentCamera
end

-- ---------------------------------------------------------------------------
-- Hold lifecycle
-- ---------------------------------------------------------------------------
local function beginHold(
    object: Instance,
    primary: BasePart,
    alignPosition: AlignPosition,
    alignOrientation: AlignOrientation
)
    local cam = getCamera()
    local holdDist = GeometryUtil.computeHoldDistance(object)

    hold = {
        object           = object,
        primary          = primary,
        alignPosition    = alignPosition,
        alignOrientation = alignOrientation,
        holdDistance     = holdDist,
        -- Fix orientation at grab-time world rotation (decision #2).
        fixedOrientGoal  = primary.CFrame.Rotation,
    }
    -- Write the fixed goal once so the constraint starts with correct orientation.
    alignOrientation.CFrame = primary.CFrame.Rotation
    isDraggingFlag = true
end

local function endHold()
    hold = nil
    isDraggingFlag = false
end

-- ---------------------------------------------------------------------------
-- Per-frame steering (RenderStepped)
-- ---------------------------------------------------------------------------
local function steerHold(dt: number)
    local current = hold
    if not current then return end

    -- Guard against the server tearing the rig down before we get DragEnded.
    if not current.primary.Parent
        or not current.alignPosition.Parent
        or not current.alignOrientation.Parent then
        endHold()
        return
    end

    local cam = getCamera()

    -- Position: move to a point holdDistance in front of the camera.
    local goalPosition = (cam.CFrame * CFrame.new(0, 0, -current.holdDistance)).Position
    current.alignPosition.Position = goalPosition

    -- Orientation: locked at grab-time (decision #2); just re-assert each frame
    -- to resist physics perturbation.
    current.alignOrientation.CFrame = current.fixedOrientGoal

    -- Auto-release if object drifts past maxHoldDistance (mirrors server leash).
    local head = localPlayer.Character and
        (localPlayer.Character :: Model):FindFirstChild("Head") :: BasePart?
    if head then
        local dist = (current.primary.Position - head.Position).Magnitude
        if dist > Config.Drag.maxHoldDistance + GeometryUtil.getBoundingRadius(current.object) then
            DragController.endDrag()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local DragController = {}

-- Called by InteractionController when the player clicks on a draggable prop.
function DragController.beginDrag(prop: Instance)
    if isDraggingFlag then return end
    local R = RemotesClient.get()
    R.DragStartRequest:FireServer(prop)
    -- Hold data is populated when DragGranted fires (below).
end

-- Called by InteractionController when the player releases the mouse.
function DragController.endDrag()
    if not isDraggingFlag then return end
    local R = RemotesClient.get()
    R.DragEndRequest:FireServer()
    endHold()
end

function DragController.isDragging(): boolean
    return isDraggingFlag
end

-- Returns the smoothed mouse-movement delta for ViewmodelController.
function DragController.getSmoothedDelta(): Vector2
    return smoothedDelta
end

function DragController.start()
    local R = RemotesClient.get()

    -- Server confirms the grab and hands us the constraint refs.
    table.insert(connections,
        R.DragGranted.OnClientEvent:Connect(function(
            object: Instance,
            primary: BasePart,
            alignPosition: AlignPosition,
            alignOrientation: AlignOrientation
        )
            if not (object and primary and alignPosition and alignOrientation) then return end
            beginHold(object, primary, alignPosition, alignOrientation)
        end)
    )

    -- Server force-dropped us (leash, death, equip conflict, etc.).
    table.insert(connections,
        R.DragEnded.OnClientEvent:Connect(function()
            endHold()
        end)
    )

    -- HoldStateChanged("None") from server also means drag ended.
    table.insert(connections,
        R.HoldStateChanged.OnClientEvent:Connect(function(kind: string)
            if kind == "None" and isDraggingFlag then
                endHold()
            end
        end)
    )

    -- Scroll-wheel adjusts hold distance.
    table.insert(connections,
        UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
            if gameProcessed then return end
            local current = hold
            if not current then return end
            if input.UserInputType == Enum.UserInputType.MouseWheel then
                current.holdDistance = math.clamp(
                    current.holdDistance - input.Position.Z * Config.Drag.scrollStep,
                    Config.Drag.holdDistanceMin,
                    Config.Drag.holdDistanceMax
                )
            end
        end)
    )

    -- Track mouse delta for ViewmodelController sway.
    table.insert(connections,
        UserInputService.InputChanged:Connect(function(input: InputObject)
            if input.UserInputType == Enum.UserInputType.MouseMovement then
                rawDelta = Vector2.new(input.Delta.X, input.Delta.Y)
            end
        end)
    )

    -- RenderStepped: smooth the delta and steer constraints.
    table.insert(connections,
        RunService.RenderStepped:Connect(function(dt: number)
            smoothedDelta = smoothedDelta:Lerp(rawDelta,
                math.clamp(dt * Config.Viewmodel.mouseSwayLerpSpeed, 0, 1))
            rawDelta = Vector2.zero
            steerHold(dt)
        end)
    )
end

function DragController.destroy()
    DragController.endDrag()
    for _, c in connections do c:Disconnect() end
    table.clear(connections)
end

return DragController
