--!strict
-- Module: Config
-- Single source of truth for every tunable value.
-- Shared between server and client — no mirrored config tables.
-- Values from the consensus build are preserved exactly; new keys added per blueprint §9.3.

local Config = {

	-- -----------------------------------------------------------------------
	-- Drag / physics (ported and de-duplicated from consensus PickupServer)
	-- -----------------------------------------------------------------------
	Drag = {
		-- Detection
		Tag = "Interactable",           -- CollectionService tag for legacy interactables
		Attribute = "Interactable",     -- boolean attribute alternative
		HeldByAttribute = "PickupHeldBy", -- runtime stamp: UserId of current holder (or nil)

		-- Reach
		maxPickupDistance = 12,
		serverDistanceTolerance = 4,   -- latency slack added to server-side distance check
		maxHoldDistance = 14,          -- leash hard limit (studs from head)
		leashGracePeriod = 0.6,        -- seconds inside breach before force-drop
		leashInterval = 0.2,           -- seconds between leash sweeps

		-- Object limits
		maxObjectMass = 5000,          -- 0 = disabled

		-- Blender pivot correction
		pivotCorrectionThreshold = 0.2,

		-- AlignPosition
		positionResponsiveness = 55,
		forceMultiplier = 50,
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90,              -- hard anti-fling cap (studs/s)

		-- AlignOrientation
		orientationResponsiveness = 50,
		torqueMultiplier = 4000,
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,

		-- Drop
		dropImpulseSpeed = 6,          -- gentle forward toss on voluntary drop

		-- Client hold framing
		holdDistanceBase = 4,
		holdDistancePadding = 1.0,     -- multiplied by object largest axis
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75,             -- studs per mouse-wheel notch

		-- Feature gate (decision #7 from blueprint)
		enableInspect = false,         -- inspect-rotate mode disabled for v1
		flingVelocityMultiplier = 1.0, -- scales emergent release velocity
	},

	-- -----------------------------------------------------------------------
	-- Viewmodel (first-person arms + gun cosmetic)
	-- -----------------------------------------------------------------------
	Viewmodel = {
		swayAmount = 0.06,                            -- viewmodel lag per radian of camera delta
		swaySpeed = 10,                               -- spring frequency (rad/s)
		bobAmount = 0.04,                             -- vertical bob peak amplitude (studs)
		bobSpeed = 14,                                -- bob oscillation frequency (rad/s)
		baseOffsetCFrame = CFrame.new(0.45, -1.6, -2.0), -- right, down, forward from camera
		springDamping = 0.8,                          -- damping ratio (0=undamped, 1=critically)
		springFrequency = 10,                         -- natural frequency for sway spring
		kickPitch = 0.12,                             -- radians of upward kick per shot
		kickRecoverySpeed = 14,                       -- how quickly kick decays
	},

	-- -----------------------------------------------------------------------
	-- Weapon (hitscan)
	-- -----------------------------------------------------------------------
	Weapon = {
		serverRayLengthPadding = 50,    -- extra studs beyond declared range on server raycast
		maxAimDeviationDegrees = 35,    -- plausibility: max angle between client dir and server look
		maxOriginDistance = 8,          -- max studs the client origin may be from the head
	},

	-- -----------------------------------------------------------------------
	-- Security / rate limiting
	-- -----------------------------------------------------------------------
	Security = {
		fireRequestCooldownMs = 50,       -- minimum ms between FireRequest events per player
		dragRequestCooldownMs = 200,      -- minimum ms between DragStartRequest events
		equipRequestCooldownMs = 500,     -- minimum ms between EquipRequest events
		maxEquipDistance = 16,            -- studs (pickup distance + tolerance)
		maxDragStartDistance = 16,        -- studs (maxPickupDistance + serverDistanceTolerance)
	},

	-- -----------------------------------------------------------------------
	-- Collision groups
	-- -----------------------------------------------------------------------
	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	-- -----------------------------------------------------------------------
	-- Networking
	-- -----------------------------------------------------------------------
	RemotesFolderName = "ItemSystemRemotes",
}

return Config
