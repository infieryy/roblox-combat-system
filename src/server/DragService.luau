--!strict
--[[
    DragService  (server)
    ---------------------
    Handles DragStartRequest and DragEndRequest.
    Ported core of the consensus PickupServer — the proven AlignPosition +
    AlignOrientation constraint rig is preserved exactly; the only behavioural
    changes for the bridge build are:

      • Trigger is now a mouse-drag request routed through InteractionController,
        not an E-key press — no code change needed here (validation is the same).
      • Orientation goal is fixed at grab time and never updated per-frame
        (decision #2: position-only drag). The AlignOrientation constraint still
        exists so it prevents spin on asymmetric props; it just doesn't follow
        the camera.
      • Rate limiting on DragStartRequest (§14.2 fix).
      • Drop impulse clamped to maxVelocity (§14.3 fix).
      • Routes through PlayerHoldState for the one-item rule.
      • Exposes forceRelease(player) so EquipService can auto-drop a held prop.

    Cross-service teardown contract (BLUEPRINT.md §16):
      DragService.onDragStart calls PlayerHoldState.setProp → if the returned
      previous hold was a Weapon, it calls EquipService.forceUnequip.
      EquipService is injected after construction via DragService.setEquipService
      to break the circular require at module load time.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared           = ReplicatedStorage:WaitForChild("Shared")
local Config           = require(Shared:WaitForChild("Config")          :: ModuleScript)
local GeometryUtil     = require(Shared:WaitForChild("GeometryUtil")    :: ModuleScript)
local ItemRegistry     = require(Shared:WaitForChild("ItemRegistry")    :: ModuleScript)
local Types            = require(Shared:WaitForChild("Types")           :: ModuleScript)

local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState  = require(script.Parent.PlayerHoldState)

local ATTACHMENT_NAME      = "PickupHoldAttachment"
local ALIGN_POSITION_NAME  = "PickupAlignPosition"
local ALIGN_ORIENTATION_NAME = "PickupAlignOrientation"

-- Injected after both services are required in init.server (breaks circular dep).
local _equipService: { forceUnequip: (Player) -> () }? = nil

-- ---------------------------------------------------------------------------
-- Session state
-- ---------------------------------------------------------------------------
type Session = {
    object:            Instance,
    primary:           BasePart,
    rig:               Types.HoldRig,
    welds:             { WeldConstraint },
    anchoredSnapshot:  { [BasePart]: boolean },
    collisionSnapshot: { [BasePart]: string },
    connections:       { RBXScriptConnection },
    boundingRadius:    number,
    breachTime:        number,
}

local sessions: { [Player]: Session } = {}
-- Per-player last-request timestamp for rate limiting.
local lastRequestAt: { [Player]: number } = {}

-- ---------------------------------------------------------------------------
-- Utility helpers (ported from consensus)
-- ---------------------------------------------------------------------------

local function getHead(player: Player): BasePart?
    local character = player.Character
    if not character then return nil end
    local head = character:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head :: BasePart end
    local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    if root and root:IsA("BasePart") then return root :: BasePart end
    return nil
end

local function isAlive(player: Player): boolean
    local character = player.Character
    if not character then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and (humanoid :: Humanoid).Health > 0
end

local function unanchor(target: Instance): { [BasePart]: boolean }
    local original: { [BasePart]: boolean } = {}
    for _, part in GeometryUtil.getParts(target) do
        original[part] = part.Anchored
        part.Anchored = false
    end
    return original
end

local function restoreAnchors(original: { [BasePart]: boolean })
    for part, anchored in original do
        if part and part.Parent then
            part.Anchored = anchored
        end
    end
end

local function weldAssembly(target: Instance, primaryPart: BasePart): { WeldConstraint }
    local welds: { WeldConstraint } = {}
    if not target:IsA("Model") then return welds end

    local connected: { [BasePart]: boolean } = {}
    for _, part in primaryPart:GetConnectedParts(true) do
        connected[part :: BasePart] = true
    end

    for _, part in GeometryUtil.getParts(target) do
        if part ~= primaryPart and not connected[part] then
            local weld = Instance.new("WeldConstraint")
            weld.Name = "PickupWeld"
            weld.Part0 = primaryPart
            weld.Part1 = part
            weld.Parent = primaryPart
            table.insert(welds, weld)
        end
    end
    return welds
end

-- Builds the AlignPosition + AlignOrientation rig.
-- Orientation goal is fixed at grab-time (decision #2: no per-frame rotation).
local function createHoldRig(target: Instance, primaryPart: BasePart): Types.HoldRig
    local mass    = math.max(primaryPart.AssemblyMass, 0.1)
    local radius  = GeometryUtil.getBoundingRadius(target)
    local gravity = Workspace.Gravity
    local centre  = GeometryUtil.getVisualCenter(target)

    local attachment = Instance.new("Attachment")
    attachment.Name   = ATTACHMENT_NAME
    -- Placed at the visual centre relative to the primary part, identity rotation.
    attachment.CFrame = CFrame.new(primaryPart.CFrame:PointToObjectSpace(centre))
    attachment.Parent = primaryPart

    local maxForce  = math.clamp(mass * gravity * Config.Drag.forceMultiplier, Config.Drag.minForce, Config.Drag.maxForce)
    local maxTorque = math.clamp(mass * (radius * radius + 1) * Config.Drag.torqueMultiplier, Config.Drag.minTorque, Config.Drag.maxTorque)

    local alignPosition = Instance.new("AlignPosition")
    alignPosition.Name                = ALIGN_POSITION_NAME
    alignPosition.Mode                = Enum.PositionAlignmentMode.OneAttachment
    alignPosition.Attachment0         = attachment
    -- Force at centre of mass so an asymmetric COM doesn't spin the prop.
    alignPosition.ApplyAtCenterOfMass = true
    alignPosition.RigidityEnabled     = false
    alignPosition.ReactionForceEnabled= false
    alignPosition.MaxForce            = maxForce
    alignPosition.MaxVelocity         = Config.Drag.maxVelocity
    alignPosition.Responsiveness      = Config.Drag.positionResponsiveness
    alignPosition.Position            = centre
    alignPosition.Parent              = primaryPart

    local alignOrientation = Instance.new("AlignOrientation")
    alignOrientation.Name                  = ALIGN_ORIENTATION_NAME
    alignOrientation.Mode                  = Enum.OrientationAlignmentMode.OneAttachment
    alignOrientation.Attachment0           = attachment
    alignOrientation.RigidityEnabled       = false
    alignOrientation.ReactionTorqueEnabled = false
    alignOrientation.MaxTorque             = maxTorque
    alignOrientation.MaxAngularVelocity    = Config.Drag.maxAngularVelocity
    alignOrientation.Responsiveness        = Config.Drag.orientationResponsiveness
    -- Fix at grab-time world orientation — the client will NOT update this (decision #2).
    alignOrientation.CFrame               = primaryPart.CFrame.Rotation
    alignOrientation.Parent               = primaryPart

    return {
        attachment      = attachment,
        alignPosition   = alignPosition,
        alignOrientation= alignOrientation,
    }
end

-- ---------------------------------------------------------------------------
-- Remotes (lazy, resolved once the folder exists)
-- ---------------------------------------------------------------------------
local _remotes: {
    DragGranted: RemoteEvent,
    DragEnded:   RemoteEvent,
}? = nil

local function getRemotes()
    if not _remotes then
        local folder = ReplicatedStorage:WaitForChild("ItemSystemRemotes")
        _remotes = {
            DragGranted = folder:WaitForChild("DragGranted") :: RemoteEvent,
            DragEnded   = folder:WaitForChild("DragEnded")   :: RemoteEvent,
        }
    end
    return _remotes :: { DragGranted: RemoteEvent, DragEnded: RemoteEvent }
end

-- ---------------------------------------------------------------------------
-- Drop / teardown
-- ---------------------------------------------------------------------------
local function dropObject(player: Player, applyImpulse: boolean)
    local session = sessions[player]
    if not session then return end
    sessions[player] = nil

    for _, connection in session.connections do
        connection:Disconnect()
    end

    if session.primary.Parent then
        PhysicsAuthority.returnOwnership(session.primary)
    end

    if session.rig.alignPosition.Parent then
        session.rig.alignPosition:Destroy()
    end
    if session.rig.alignOrientation.Parent then
        session.rig.alignOrientation:Destroy()
    end
    if session.rig.attachment.Parent then
        session.rig.attachment:Destroy()
    end

    for _, weld in session.welds do
        if weld.Parent then weld:Destroy() end
    end

    PhysicsAuthority.restoreGroups(session.collisionSnapshot)
    restoreAnchors(session.anchoredSnapshot)

    if session.object.Parent then
        session.object:SetAttribute(Config.HeldByAttribute, nil)
    end

    if applyImpulse and session.primary.Parent then
        local head = getHead(player)
        if head then
            -- Clamp the impulse so it cannot exceed maxVelocity (§14.3 fix).
            local speed = math.min(Config.Drag.dropImpulseSpeed, Config.Drag.maxVelocity)
            session.primary.AssemblyLinearVelocity = head.CFrame.LookVector * speed
                * Config.Drag.flingVelocityMultiplier
        end
    end

    if player.Parent then
        getRemotes().DragEnded:FireClient(player, session.object)
    end
end

-- ---------------------------------------------------------------------------
-- Leash anti-cheat loop (ported from consensus)
-- ---------------------------------------------------------------------------
local function startLeashLoop()
    local accumulator = 0
    RunService.Heartbeat:Connect(function(dt: number)
        accumulator += dt
        if accumulator < Config.Drag.leashInterval then return end
        local elapsed = accumulator
        accumulator = 0

        for player, session in sessions do
            if not session.primary.Parent
                or not session.primary:IsDescendantOf(Workspace)
                or not isAlive(player) then
                dropObject(player, false)
                continue
            end

            local head = getHead(player)
            if not head then
                dropObject(player, false)
                continue
            end

            local maxDist = Config.Drag.maxHoldDistance + session.boundingRadius
            local dist    = (session.primary.Position - head.Position).Magnitude
            if dist > maxDist then
                session.breachTime += elapsed
                if session.breachTime > Config.Drag.leashGracePeriod then
                    dropObject(player, false)
                end
            else
                session.breachTime = 0
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
local DragService = {}

-- Inject EquipService reference after both services are required (breaks the
-- circular require at module-load time).
function DragService.setEquipService(svc: { forceUnequip: (Player) -> () })
    _equipService = svc
end

-- Called by the server's DragStartRequest handler.
function DragService.onDragStart(player: Player, requested: unknown)
    -- One object at a time.
    if sessions[player] then return end

    -- Rate limiting (§14.2 fix).
    local now = os.clock()
    local last = lastRequestAt[player] or 0
    if (now - last) * 1000 < Config.Security.dragRequestCooldownMs then return end
    lastRequestAt[player] = now

    if typeof(requested) ~= "Instance" then return end
    local instance = requested :: Instance
    if not instance:IsDescendantOf(Workspace) then return end
    if not isAlive(player) then return end

    -- Classify: must be a draggable prop.
    if not ItemRegistry.isDraggable(instance) then return end

    -- Resolve to the top-level interactable (never trust the raw hit part).
    local function resolveUp(hit: Instance): Instance?
        local node: Instance? = hit
        while node and node ~= Workspace do
            if ItemRegistry.classify(node) == "Prop" then return node end
            node = (node :: Instance).Parent
        end
        return nil
    end
    local object = resolveUp(instance)
    if not object then return end

    -- Already held?
    if object:GetAttribute(Config.HeldByAttribute) ~= nil then return end

    local primary = GeometryUtil.getPrimaryPart(object)
    if not primary or primary.Anchored then return end

    -- Server-authoritative distance check (measures to visual centre to handle
    -- off-pivot Blender imports correctly).
    local head = getHead(player)
    if not head then return end
    local centre       = GeometryUtil.getVisualCenter(object)
    local boundRadius  = GeometryUtil.getBoundingRadius(object)
    local distance     = (centre - head.Position).Magnitude - boundRadius
    if distance > Config.Security.maxDragStartDistance then return end

    -- Mass sanity.
    if Config.Drag.maxObjectMass > 0 and primary.AssemblyMass > Config.Drag.maxObjectMass then
        return
    end

    -- One-item rule: register prop hold; if previous hold was a weapon, unequip it.
    local prev = PlayerHoldState.setProp(player, object)
    if prev.kind == "Weapon" and _equipService then
        _equipService.forceUnequip(player)
    end

    -- Commit: weld → ownership → rig.
    local anchoredSnapshot = unanchor(object)
    local welds            = weldAssembly(object, primary)

    if not PhysicsAuthority.giveOwnership(primary, player) then
        for _, w in welds do w:Destroy() end
        restoreAnchors(anchoredSnapshot)
        PlayerHoldState.clear(player)
        return
    end

    local collisionSnapshot = PhysicsAuthority.applyHeldGroup(object)
    local rig               = createHoldRig(object, primary)
    object:SetAttribute(Config.HeldByAttribute, player.UserId)

    local session: Session = {
        object            = object,
        primary           = primary,
        rig               = rig,
        welds             = welds,
        anchoredSnapshot  = anchoredSnapshot,
        collisionSnapshot = collisionSnapshot,
        connections       = {},
        boundingRadius    = boundRadius,
        breachTime        = 0,
    }
    sessions[player] = session

    -- Auto-drop if the object is removed mid-hold (e.g. someone deleted it).
    table.insert(session.connections,
        object.AncestryChanged:Connect(function(_, parent)
            if not parent then dropObject(player, false) end
        end)
    )
    table.insert(session.connections,
        primary.AncestryChanged:Connect(function(_, parent)
            if not parent then dropObject(player, false) end
        end)
    )

    -- Hand the owning client the constraint refs to steer locally every frame.
    getRemotes().DragGranted:FireClient(player, object, primary, rig.alignPosition, rig.alignOrientation)
end

-- Called by the server's DragEndRequest handler.
function DragService.onDragEnd(player: Player)
    if not sessions[player] then return end
    dropObject(player, true)
    PlayerHoldState.clear(player)
end

-- Called by EquipService when equipping a weapon while a prop is held.
function DragService.forceRelease(player: Player)
    if not sessions[player] then return end
    dropObject(player, false)
    -- PlayerHoldState is already being set by EquipService; don't clear again.
end

function DragService.start()
    startLeashLoop()
end

return DragService
