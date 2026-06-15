--!strict
-- Module: shared/Config
-- THE single source of truth for every tunable value (BLUEPRINT.md §9.3).
-- The consensus build mirrored its config across the server and client scripts;
-- this module removes that duplication (§14.1) — both sides require this copy.

local Config = {
	-- ============================================================ Drag / props
	-- Ported verbatim from the consensus PickupServer.Config plus the client
	-- framing values, merged into one table.
	Drag = {
		-- Reach / distances (studs)
		maxPickupDistance = 12,
		serverDistanceTolerance = 4, -- latency slack on the server distance check
		maxHoldDistance = 14, -- leash radius (plus the prop's bounding radius)
		leashGracePeriod = 0.6, -- s outside the leash before a force-drop
		leashInterval = 0.2, -- s between leash sweeps

		-- Object limits
		maxObjectMass = 5000, -- reject heavier assemblies (0 disables)

		-- Blender pivot correction: if the pivot sits further than this fraction
		-- of the bounding-box diagonal from the box centre, carry by the box
		-- centre instead so off-centre imports hover centred.
		pivotCorrectionThreshold = 0.2,

		-- AlignPosition tuning
		positionResponsiveness = 55, -- 0-200, higher = snappier
		forceMultiplier = 50, -- MaxForce = clamp(mass*gravity*mult, min, max)
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90, -- hard anti-fling / anti-tunnel cap

		-- AlignOrientation tuning
		orientationResponsiveness = 50,
		torqueMultiplier = 4000, -- MaxTorque = clamp(mass*(r^2+1)*mult, min, max)
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,

		-- Client framing: how far in front of the camera the prop floats.
		holdDistanceBase = 4,
		holdDistancePadding = 1.0,
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75, -- studs per mouse-wheel notch

		-- Bridge decisions (BLUEPRINT.md §2)
		enableInspect = false, -- consensus inspect-rotate gated off (decision #7)
		rotateSensitivity = 0.0125, -- only used when enableInspect = true
		flingVelocityMultiplier = 1.0, -- emergent fling scaling on release
		dropImpulseSpeed = 6, -- legacy gentle toss (only if velocity is ~0)
	},

	-- ============================================================ Viewmodel
	Viewmodel = {
		baseOffsetCFrame = CFrame.new(1.0, -1.2, -1.8) * CFrame.Angles(0, math.rad(-4), 0),
		swayAmount = 0.06, -- studs/radians of look-delta translated into sway
		swaySpeed = 7, -- spring approach speed for sway
		bobAmount = 0.05, -- walk-bob amplitude (studs)
		bobSpeed = 9, -- walk-bob frequency multiplier
		springDamping = 0.72,
		springFrequency = 9,
		maxSwayOffset = 0.18, -- clamp so fast flicks never throw the gun off-screen
		fireKick = CFrame.new(0, 0.05, 0.32) * CFrame.Angles(math.rad(7), 0, 0),
		fireKickRecover = 12, -- per-second recovery speed of the fire kick
	},

	-- ============================================================ Weapon
	Weapon = {
		serverRayLengthPadding = 2, -- extra studs added to def.range server-side
		maxAimDeviationDegrees = 12, -- plausibility: angle(client dir, real look)
		maxOriginDeviation = 8, -- studs the claimed origin may sit from the head
		tracerDuration = 0.06, -- s a client tracer beam stays visible
		tracerWidth = 0.08,
	},

	-- ============================================================ Security
	-- Per-remote rate limits (BLUEPRINT.md §14.2 — the consensus had none).
	Security = {
		fireRequestCooldownMs = 35, -- backstop under the per-weapon fire rate
		dragRequestCooldownMs = 120,
		equipRequestCooldownMs = 200,
		unequipRequestCooldownMs = 200,
		reloadRequestCooldownMs = 400,
		maxEquipDistance = 14,
		maxDragStartDistance = 16, -- mirrors maxPickupDistance + serverDistanceTolerance
	},

	-- ============================================================ Physics groups
	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	-- ============================================================ Item attributes
	-- Studio-set keys read by ItemRegistry (BLUEPRINT.md §12).
	Attributes = {
		itemType = "ItemType", -- "Weapon" | "Prop"
		weaponId = "WeaponId", -- registry key on weapon instances
		interactable = "Interactable", -- legacy bool attribute -> Prop
		draggable = "Draggable", -- optional bool; false locks a prop
		heldBy = "PickupHeldBy", -- runtime UserId stamp while held
		equippedWeaponId = "EquippedWeaponId", -- runtime stamp on a character
	},

	-- CollectionService tag that (legacy) flags a Prop.
	InteractTag = "Interactable",

	-- ============================================================ Networking
	RemotesFolderName = "ItemSystemRemotes",
}

return Config
