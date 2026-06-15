--!strict
-- Module: Central tunables for drag, weapons, viewmodel, and security.

local Config = {
	Drag = {
		tag = "Interactable",
		attribute = "Interactable",
		heldByAttribute = "PickupHeldBy",
		weaponHeldByAttribute = "WeaponHeldBy",

		maxPickupDistance = 12,
		serverDistanceTolerance = 4,
		maxHoldDistance = 14,
		leashGracePeriod = 0.6,
		leashInterval = 0.2,

		maxObjectMass = 5000,
		pivotCorrectionThreshold = 0.2,

		positionResponsiveness = 55,
		forceMultiplier = 50,
		minForce = 30000,
		maxForce = 8_000_000,
		maxVelocity = 90,

		orientationResponsiveness = 50,
		torqueMultiplier = 4000,
		minTorque = 40000,
		maxTorque = 8_000_000,
		maxAngularVelocity = 35,

		dropImpulseSpeed = 6,
		flingVelocityMultiplier = 1.0,
		enableInspect = false,

		holdDistanceBase = 4,
		holdDistancePadding = 1.0,
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75,
	},

	Viewmodel = {
		baseOffsetCFrame = CFrame.new(0.6, -0.8, -1.2),
		swayAmount = 0.9,
		swaySpeed = 10,
		bobAmount = 0.06,
		bobSpeed = 8,
		kickDistance = 0.08,
		kickReturnSpeed = 14,
		springDamping = 0.8,
		springFrequency = 8,
	},

	Weapon = {
		serverRayLengthPadding = 3,
		maxAimDeviationDegrees = 30,
		defaultReloadKey = Enum.KeyCode.R,
	},

	Security = {
		fireRequestCooldownMs = 65,
		dragRequestCooldownMs = 60,
		equipRequestCooldownMs = 150,
		maxEquipDistance = 14,
		maxDragStartDistance = 16,
	},

	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	RemotesFolderName = "ItemSystemRemotes",
}

return Config
