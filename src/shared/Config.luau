--!strict
-- Module: Config
-- Single source of truth for all tunable values.

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
		swayAmount = 0.025,
		swaySpeed = 8,
		bobAmount = 0.04,
		bobSpeed = 12,
		baseOffsetCFrame = CFrame.new(0.5, -0.6, -1.2),
		springDamping = 0.8,
		springFrequency = 6,
		forceFirstPerson = true,
		assetsFolderName = "Assets",
		viewmodelsFolderName = "Viewmodels",
	},

	Weapon = {
		serverRayLengthPadding = 2,
		maxAimDeviationDegrees = 12,
		tracerLifetime = 0.08,
		tracerWidth = 0.05,
	},

	Security = {
		fireRequestCooldownMs = 50,
		dragRequestCooldownMs = 150,
		equipRequestCooldownMs = 300,
		reloadRequestCooldownMs = 500,
		maxEquipDistance = 12,
		maxDragStartDistance = 16,
	},

	CollisionGroups = {
		heldObjects = "PickupHeldObjects",
		characters = "PickupCharacters",
		defaultGroup = "Default",
	},

	RemotesFolderName = "ItemSystemRemotes",

	Input = {
		equipKey = Enum.KeyCode.E,
		dropKey = Enum.KeyCode.Q,
		inspectKey = Enum.KeyCode.R,
		gamepadEquipKey = Enum.KeyCode.ButtonR1,
		gamepadInspectKey = Enum.KeyCode.ButtonL1,
	},
}

return Config
