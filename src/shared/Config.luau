--!strict
--[[
	Config  (shared/Config.luau → ReplicatedStorage.Shared.Config)
	---------------------------------------------------------------
	Single source of truth for every tunable value in the system.
	Both the server and client require this one copy — no mirrored configs.
	Change a value here and it takes effect everywhere.
]]

local Config = {

	-- ------------------------------------------------------------------
	-- Drag (physics grab — props only, mouse-held)
	-- ------------------------------------------------------------------
	Drag = {
		-- Client raycast distance for finding a draggable prop.
		maxPickupDistance = 12,
		-- Extra slack on the server's distance check to absorb latency.
		serverDistanceTolerance = 4,
		-- Server leash: force-drop when the held object drifts this far from the head.
		maxHoldDistance = 14,
		-- Grace period (s) before the leash fires — absorbs physics overshoots.
		leashGracePeriod = 0.6,
		-- Seconds between server leash sweeps.
		leashInterval = 0.2,
		-- Reject objects heavier than this. 0 = no limit.
		maxObjectMass = 5000,
		-- If a model's pivot deviates more than this fraction of the bounding-box
		-- diagonal from the visual centre, use the bounding-box centre instead.
		-- This corrects off-centre Blender pivots.
		pivotCorrectionThreshold = 0.2,

		-- AlignPosition
		positionResponsiveness = 55,
		forceMultiplier = 50,
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90,

		-- AlignOrientation
		orientationResponsiveness = 50,
		torqueMultiplier = 4000,
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,

		-- Gentle forward toss on drop.
		dropImpulseSpeed = 6,

		-- Client hold offset: how far in front of the camera the object floats.
		holdDistanceBase = 4,
		holdDistancePadding = 1.0,
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75,

		-- Bridge decision #7: inspect-rotate is gated off for v1.
		-- Set to true in a future release to re-enable spinning held props.
		enableInspect = false,
		-- Multiplier applied to residual velocity when the mouse is released.
		-- 1.0 = pure emergent fling from AlignPosition momentum.
		flingVelocityMultiplier = 1.0,
	},

	-- ------------------------------------------------------------------
	-- Viewmodel (first-person arms + gun — cosmetic, client only)
	-- ------------------------------------------------------------------
	Viewmodel = {
		-- Base CFrame offset from the camera origin to the viewmodel pivot.
		-- Tune these to match your arm rig's grip point.
		baseOffsetCFrame = CFrame.new(0.5, -1.2, -1.8),

		-- Look-sway: how much the viewmodel lags behind camera rotation.
		swayAmount = 0.04,
		swaySpeed  = 12,   -- spring stiffness (higher = snappier)

		-- Walk-bob amplitude (studs) and frequency (cycles/s).
		bobAmount = 0.06,
		bobSpeed  = 8,

		-- Recoil kick velocity (degrees/s) applied upward on fire.
		kickVelocity = 6,

		-- Spring parameters (damping ratio, undamped natural freq in rad/s).
		springDamping   = 0.65,
		springFrequency = 18,
	},

	-- ------------------------------------------------------------------
	-- Weapon (server-side hitscan)
	-- ------------------------------------------------------------------
	Weapon = {
		-- Extra stud padding added to the weapon's range for the server ray.
		serverRayLengthPadding = 5,
		-- Maximum angle (degrees) between the client's direction and the server's
		-- knowledge of the player's look vector before the shot is rejected.
		-- Wide tolerance because camera pitch can differ from HRP facing.
		maxAimDeviationDegrees = 60,
		-- Maximum studs the client's claimed origin may be from the server's
		-- known head position before the shot is rejected.
		maxOriginDeviation = 8,
	},

	-- ------------------------------------------------------------------
	-- Security (rate limits for every C→S remote)
	-- ------------------------------------------------------------------
	Security = {
		-- Minimum milliseconds between DragStartRequest fires per player.
		dragRequestCooldownMs = 100,
		-- Minimum milliseconds between EquipRequest fires per player.
		equipRequestCooldownMs = 500,
		-- Minimum milliseconds between UnequipRequest fires per player.
		unequipRequestCooldownMs = 200,
		-- Minimum milliseconds between FireRequest fires (enforced per-weapon RoF anyway).
		fireRequestCooldownMs = 50,
		-- Maximum equip distance from the player's head to the weapon.
		maxEquipDistance = 14,
		-- Combined drag distance used in DragService validation.
		maxDragStartDistance = 12 + 4, -- maxPickupDistance + serverDistanceTolerance
	},

	-- ------------------------------------------------------------------
	-- Collision groups (registered at runtime by PhysicsAuthority)
	-- ------------------------------------------------------------------
	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters  = "PickupCharacters",
		default     = "Default",
	},

	-- ------------------------------------------------------------------
	-- Shared constants
	-- ------------------------------------------------------------------
	RemotesFolderName = "ItemSystemRemotes",
	HeldByAttribute   = "PickupHeldBy",

	-- Tags / attributes that mark interactable objects (backward-compat).
	LegacyTag       = "Interactable",
	LegacyAttribute = "Interactable",
	ItemTypeAttribute = "ItemType",  -- "Weapon" or "Prop"
	WeaponIdAttribute = "WeaponId",
	DraggableAttribute = "Draggable",
}

return Config
