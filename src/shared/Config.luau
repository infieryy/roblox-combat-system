--!strict
-- Module: Config
-- Single source of truth for every tunable constant.
-- Both server and client require this. No mirrored config blocks allowed.

local Config = {

	-- -------------------------------------------------------------------------
	-- Drag / physics rig
	-- All physics values ported from the consensus PickupServer build.
	-- -------------------------------------------------------------------------
	Drag = {
		maxPickupDistance = 12,           -- studs; client raycast + server validation
		serverDistanceTolerance = 4,      -- latency slack on server distance check
		maxHoldDistance = 14,             -- leash radius (studs from head)
		leashGracePeriod = 0.6,           -- seconds before leash kicks the object loose
		leashInterval = 0.2,              -- seconds between leash sweeps
		maxObjectMass = 5000,             -- kg; reject absurdly heavy assemblies
		pivotCorrectionThreshold = 0.2,   -- fraction of bbox diagonal; Blender fix

		-- AlignPosition
		positionResponsiveness = 55,      -- 0–200; higher = snappier
		forceMultiplier = 50,             -- MaxForce = clamp(mass*g*mult, min, max)
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90,                 -- studs/s velocity cap (key anti-fling guard)

		-- AlignOrientation
		orientationResponsiveness = 50,
		torqueMultiplier = 4000,
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,          -- rad/s angular velocity cap

		-- Drop impulse
		dropImpulseSpeed = 6,             -- studs/s forward toss on deliberate drop

		-- Client hold framing
		holdDistanceBase = 4,             -- studs; base hold distance
		holdDistancePadding = 1.0,        -- per-unit added by largest bbox axis
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75,                -- studs per scroll notch

		-- Bridge decisions
		enableInspect = false,            -- inspect-rotate gated off (decision #7)
		flingVelocityMultiplier = 1.0,    -- emergent fling on mouse release
	},

	-- -------------------------------------------------------------------------
	-- Viewmodel
	-- -------------------------------------------------------------------------
	Viewmodel = {
		baseOffset = CFrame.new(0, -1.15, -1.1), -- camera-relative arm position
		mouseSwayScale = 0.0035,          -- radians of tilt per pixel of mouse delta
		mouseSwayLerpSpeed = 12,          -- lerp speed toward sway target
		dragLerpSpeed = 10,               -- lerp speed for position drag offset
		dragClamp = Vector2.new(20, 20),  -- max pixel delta before clamping
		bobAmount = 0.04,                 -- studs of vertical bob at full run speed
		bobSpeed = 12,                    -- sine frequency for walk bob
	},

	-- -------------------------------------------------------------------------
	-- Weapon (server hitscan validation)
	-- -------------------------------------------------------------------------
	Weapon = {
		serverRayLengthPadding = 10,      -- extra studs added to def.range for ray
		maxAimDeviationDegrees = 25,      -- plausibility: client dir vs server look
	},

	-- -------------------------------------------------------------------------
	-- Security / rate limiting  (all in seconds)
	-- -------------------------------------------------------------------------
	Security = {
		fireRequestCooldown = 0.05,       -- hard floor; rejects >20 events/s
		dragRequestCooldown = 0.1,        -- prevents rapid grab spam
		equipRequestCooldown = 0.3,
		maxEquipDistance = 10,            -- studs; E-to-equip reach
		maxDragStartDistance = 16,        -- maxPickupDistance + serverDistanceTolerance
	},

	-- -------------------------------------------------------------------------
	-- Collision groups
	-- -------------------------------------------------------------------------
	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	-- -------------------------------------------------------------------------
	-- Detection (tag / attribute names; backward-compat with consensus build)
	-- -------------------------------------------------------------------------
	Detection = {
		tag = "Interactable",             -- CollectionService tag (legacy Prop)
		attribute = "Interactable",       -- boolean attribute (legacy Prop)
		itemTypeAttribute = "ItemType",   -- "Weapon" | "Prop"
		weaponIdAttribute = "WeaponId",   -- registry key string, e.g. "rifle"
		draggableAttribute = "Draggable", -- bool; false locks a Prop
		heldByAttribute = "PickupHeldBy", -- runtime UserId stamp while held
	},

	-- -------------------------------------------------------------------------
	-- Remotes
	-- -------------------------------------------------------------------------
	RemotesFolderName = "ItemSystemRemotes",
}

return Config
