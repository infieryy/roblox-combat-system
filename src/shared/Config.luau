--!strict
-- Module: shared/Config
-- The single, frozen-key source of truth for every tunable. The consensus
-- build duplicated its config across the server and client scripts; this kills
-- that duplication (§14.1) — both sides require this one copy.

local Config = {
	-- ================================================================
	-- DRAG (props) — ported tunables from the consensus PickupServer plus
	-- the client framing values, merged into one table.
	-- ================================================================
	Drag = {
		-- Reach / distances (studs)
		maxPickupDistance = 12,
		serverDistanceTolerance = 4, -- latency slack on the server distance check
		maxHoldDistance = 14, -- hard leash radius (plus the object's bounding radius)
		leashGracePeriod = 0.6, -- seconds outside the leash before a forced drop
		leashInterval = 0.2, -- seconds between leash sweeps

		-- Object limits
		maxObjectMass = 5000, -- reject absurdly heavy assemblies (0 disables)

		-- Blender pivot correction: if a model's pivot sits further than this
		-- fraction of its bounding-box diagonal from the box centre, carry it by
		-- the box centre instead (keeps off-origin imports centred).
		pivotCorrectionThreshold = 0.2,

		-- AlignPosition tuning (mass-scaled force = consistent acceleration)
		positionResponsiveness = 55,
		forceMultiplier = 50,
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90, -- key anti-fling cap; also clamps the drop/fling impulse

		-- AlignOrientation tuning (inertia-aware torque)
		orientationResponsiveness = 50,
		torqueMultiplier = 4000,
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,

		-- Drop / fling
		dropImpulseSpeed = 6, -- gentle forward toss on a deliberate drop
		flingVelocityMultiplier = 1.0, -- emergent fling scaling on release

		-- Client hold framing
		holdDistanceBase = 4,
		holdDistancePadding = 1.0,
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75, -- studs per mouse-wheel notch

		-- Bridge decisions
		enableInspect = false, -- consensus inspect-rotate gated off (decision #7)
		rotateSensitivity = 0.0125, -- only used if enableInspect = true
	},

	-- ================================================================
	-- VIEWMODEL (client-only cosmetic arms + gun)
	-- ================================================================
	Viewmodel = {
		-- Base placement of the viewmodel relative to the camera (camera space:
		-- +X right, +Y up, -Z forward).
		baseOffsetCFrame = CFrame.new(0.85, -1.0, -1.55) * CFrame.Angles(0, math.rad(-3), 0),

		-- Look-sway: how far the viewmodel lags behind fast camera rotation.
		swayAmount = 0.55, -- studs of positional sway per unit of rotation delta
		swayRotationAmount = 0.06, -- radians of rotational sway per unit of delta
		swayMaxOffset = 0.6, -- clamp so sway never flies off-screen

		-- Walk-bob: sinusoidal bob scaled by movement speed.
		bobAmount = 0.06,
		bobSpeed = 9,

		-- Spring smoothing for sway/recoil recovery (critically-damped-ish).
		springStiffness = 90,
		springDamping = 14,

		-- Recoil applied on fire (camera-space kick that springs back).
		recoilKick = CFrame.new(0, 0.05, 0.28) * CFrame.Angles(math.rad(6), 0, 0),
	},

	-- ================================================================
	-- WEAPON (shooting)
	-- ================================================================
	Weapon = {
		serverRayLengthPadding = 2, -- studs added to def.range for the server ray
		maxAimDeviationDegrees = 20, -- plausibility cone: client dir vs real look
		maxOriginDeviation = 8, -- studs the client origin may sit from the head
		tracerWidth = 0.12,
		tracerLifetime = 0.06,
		impactLifetime = 0.6,
	},

	-- ================================================================
	-- SECURITY (per-remote rate limits, in milliseconds) — §14.2
	-- ================================================================
	Security = {
		fireRequestCooldownMs = 40,
		dragRequestCooldownMs = 150,
		equipRequestCooldownMs = 200,
		unequipRequestCooldownMs = 150,
		reloadRequestCooldownMs = 400,
		maxEquipDistance = 14,
		maxDragStartDistance = 12 + 4, -- mirror maxPickupDistance + serverDistanceTolerance
	},

	-- ================================================================
	-- INPUT (key bindings)
	-- ================================================================
	Input = {
		equipKey = Enum.KeyCode.E, -- equip a looked-at weapon
		unequipKey = Enum.KeyCode.G, -- put the gun away
		reloadKey = Enum.KeyCode.R, -- reload (inspect is gated off, so R is free)
		gamepadEquipKey = Enum.KeyCode.ButtonY,
		gamepadFireButton = Enum.KeyCode.ButtonR2,
		gamepadReloadKey = Enum.KeyCode.ButtonX,
	},

	-- ================================================================
	-- COLLISION GROUPS & NETWORKING (created at runtime)
	-- ================================================================
	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	RemotesFolderName = "ItemSystemRemotes",
	HeldByAttribute = "PickupHeldBy", -- UserId stamp while an item is held
}

return Config
