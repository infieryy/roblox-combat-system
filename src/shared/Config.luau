--!strict
-- Module: Config
-- Single source of truth for every tunable value in the item & combat system.

local Config = {
	Attributes = {
		heldBy = "PickupHeldBy",
		itemType = "ItemType",
		weaponId = "WeaponId",
		interactable = "Interactable",
		draggable = "Draggable",
	},

	Legacy = {
		tag = "Interactable",
	},

	Input = {
		equipKey = Enum.KeyCode.E,
		dropKey = Enum.KeyCode.Q,
		reloadKey = Enum.KeyCode.R,
		rotateKey = Enum.KeyCode.R,
		gamepadEquipKey = Enum.KeyCode.ButtonR1,
		gamepadRotateKey = Enum.KeyCode.ButtonL1,
	},

	Drag = {
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
		enableInspect = false,
		flingVelocityMultiplier = 1.0,
		rotateSensitivity = 0.0125,
	},

	Viewmodel = {
		swayAmount = 0.025,
		swaySpeed = 10,
		bobAmount = 0.035,
		bobSpeed = 14,
		baseOffsetCFrame = CFrame.new(0.55, -1.15, -1.45),
		springDamping = 0.82,
		springFrequency = 14,
		fireKickAmount = 0.08,
		fireKickRecovery = 18,
		viewmodelsFolderName = "Viewmodels",
	},

	Weapon = {
		serverRayLengthPadding = 2,
		maxAimDeviationDegrees = 45,
		tracerLifetime = 0.08,
		impactLifetime = 2,
		muzzleFlashLifetime = 0.05,
		reloadDuration = 1.8,
	},

	Security = {
		fireRequestCooldownMs = 50,
		dragRequestCooldownMs = 200,
		equipRequestCooldownMs = 300,
		reloadRequestCooldownMs = 500,
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
