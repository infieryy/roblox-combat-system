--!strict
--[[
    Config
    ------
    Single source of truth for every tunable value in the system.
    Required by both client and server — no mirrored or duplicated config.

    Keys are frozen (changing a key = breaking change that requires a PR touching
    every consumer). Values may be tuned freely.
]]

local Config = {

    ---------------------------------------------------------------------------
    -- Drag / physics
    ---------------------------------------------------------------------------
    Drag = {
        -- Pickup reach: client raycasts up to this distance; server re-checks
        -- with +serverDistanceTolerance to absorb network latency.
        maxPickupDistance         = 12,
        serverDistanceTolerance   = 4,

        -- Hard leash: if the held object drifts further than this from the
        -- player's head (plus its own bounding radius) for longer than
        -- leashGracePeriod, the server force-drops it (anti-cheat).
        maxHoldDistance           = 14,
        leashGracePeriod          = 0.6,  -- seconds of grace before drop
        leashInterval             = 0.2,  -- seconds between leash sweeps

        -- Reject extremely heavy assemblies to prevent grief/freeze exploits.
        maxObjectMass             = 5000,

        -- Dynamic Blender pivot correction: if the model's pivot is closer
        -- than this fraction of the bounding-box diagonal to the box centre,
        -- we trust the pivot; otherwise we use the box centre as the carry point.
        pivotCorrectionThreshold  = 0.2,

        -- AlignPosition tuning -------------------------------------------------
        positionResponsiveness    = 55,
        -- maxForce = clamp(mass × gravity × forceMultiplier, minForce, maxForce)
        forceMultiplier           = 50,
        minForce                  = 30_000,
        maxForce                  = 8_000_000,
        -- Velocity cap: the primary anti-fling guard.
        maxVelocity               = 90,

        -- AlignOrientation tuning -----------------------------------------------
        orientationResponsiveness = 50,
        -- maxTorque = clamp(mass × (radius² + 1) × torqueMultiplier, min, max)
        torqueMultiplier          = 4_000,
        minTorque                 = 40_000,
        maxTorque                 = 8_000_000,
        maxAngularVelocity        = 35,

        -- Gentle forward impulse applied when a prop is deliberately dropped.
        dropImpulseSpeed          = 6,

        -- Client-side hold framing: object floats this far in front of camera,
        -- pushed back automatically by its own size so large meshes stay in frame.
        holdDistanceBase          = 4,
        holdDistancePadding       = 1.0,
        holdDistanceMin           = 3,
        holdDistanceMax           = 10,
        scrollStep                = 0.75, -- studs per mouse-wheel notch

        -- Decision #7: inspect-rotate is gated off for v1 (decision #2 = no rotation).
        enableInspect             = false,
        -- Emergent fling velocity multiplier (applied to retained velocity on release).
        flingVelocityMultiplier   = 1.0,
    },

    ---------------------------------------------------------------------------
    -- Viewmodel (client-only cosmetic)
    ---------------------------------------------------------------------------
    Viewmodel = {
        -- Base CFrame offset from camera origin to viewmodel root.
        baseOffset         = CFrame.new(0, -1.15, -1.1),

        -- Look-sway: how much camera-rotation delta tilts the arms.
        mouseSwayScale     = 0.0035,
        mouseSwayLerpSpeed = 12,

        -- Drag-lag clamp (pixels/frame).
        dragClamp          = Vector2.new(20, 20),

        -- Walk bob: amplitude in studs and oscillation rate.
        bobAmount          = 0.055,
        bobSpeed           = 10,

        -- Fire kick: CFrame.Angles amplitude and recovery speed.
        kickAmount         = 0.18,   -- radians of upward kick
        kickRecoverySpeed  = 8,      -- lerp factor per second
    },

    ---------------------------------------------------------------------------
    -- Weapon (hitscan)
    ---------------------------------------------------------------------------
    Weapon = {
        -- Extra studs added to the client-supplied range for the server raycast.
        serverRayLengthPadding  = 5,
        -- Server rejects fires where the client direction deviates more than this
        -- from the player's real look vector.
        maxAimDeviationDegrees  = 15,
    },

    ---------------------------------------------------------------------------
    -- Security / rate limiting (all C→S remotes are throttled)
    ---------------------------------------------------------------------------
    Security = {
        fireRequestCooldownMs   = 50,   -- minimum ms between FireRequest events
        dragRequestCooldownMs   = 200,  -- minimum ms between DragStartRequest events
        equipRequestCooldownMs  = 500,  -- minimum ms between EquipRequest events
        maxEquipDistance        = 10,   -- studs; weapons beyond this are rejected
        -- Must mirror Drag.maxPickupDistance + Drag.serverDistanceTolerance.
        maxDragStartDistance    = 16,
    },

    ---------------------------------------------------------------------------
    -- Collision groups (names must match the groups created by PhysicsAuthority)
    ---------------------------------------------------------------------------
    CollisionGroups = {
        heldObjects = "PickupHeldObjects",
        characters  = "PickupCharacters",
        default     = "Default",
    },

    ---------------------------------------------------------------------------
    -- Networking
    ---------------------------------------------------------------------------
    -- Folder name in ReplicatedStorage that holds all RemoteEvents.
    RemotesFolderName = "ItemSystemRemotes",

    ---------------------------------------------------------------------------
    -- Instance attributes (keys stamped on instances at runtime)
    ---------------------------------------------------------------------------
    HeldByAttribute       = "PickupHeldBy",   -- UserId while held; nil when free
    ItemTypeAttribute     = "ItemType",        -- "Weapon" | "Prop"
    WeaponIdAttribute     = "WeaponId",        -- registry key, e.g. "rifle"
    DraggableAttribute    = "Draggable",       -- explicit false → locked prop
    InteractableTag       = "Interactable",    -- CollectionService backward-compat
    InteractableAttribute = "Interactable",    -- boolean attribute backward-compat
}

return Config
