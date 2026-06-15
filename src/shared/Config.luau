--!strict
-- Module: Config
-- Single source of truth for all tunables (ported from consensus + new combat keys).

local Config = {
	Drag = {
		tag = "Interactable",
		attribute = "Interactable",
		heldByAttribute = "PickupHeldBy",

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

		holdDistanceBase = 4,
		holdDistancePadding = 1.0,
		holdDistanceMin = 3,
		holdDistanceMax = 10,
		scrollStep = 0.75,
		rotateSensitivity = 0.0125,

		enableInspect = false,
		flingVelocityMultiplier = 1.0,
	},

	Viewmodel = {
		swayAmount = 0.85,
		swaySpeed = 10,
		bobAmount = 0.06,
		bobSpeed = 14,
		baseOffsetCFrame = CFrame.new(0.55, -0.75, -1.15),
		springDamping = 0.82,
		springFrequency = 14,
		fireKickAmount = 0.08,
		fireKickRecovery = 18,
		assetsFolderName = "Viewmodels",
	},

	Weapon = {
		serverRayLengthPadding = 2,
		maxAimDeviationDegrees = 45,
		tracerLifetime = 0.08,
		impactLifetime = 0.35,
	},

	Security = {
		fireRequestCooldownMs = 50,
		dragRequestCooldownMs = 100,
		equipRequestCooldownMs = 200,
		reloadRequestCooldownMs = 500,
		maxEquipDistance = 12,
		maxDragStartDistance = 16,
		maxOriginDistanceFromHead = 6,
	},

	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		default = "Default",
	},

	RemotesFolderName = "ItemSystemRemotes",

	Input = {
		equipKey = Enum.KeyCode.E,
		dropKey = Enum.KeyCode.Q,
		inspectKey = Enum.KeyCode.R,
		gamepadEquipKey = Enum.KeyCode.ButtonR1,
		gamepadInspectKey = Enum.KeyCode.ButtonL1,
		forceFirstPerson = true,
	},
}

return Config
