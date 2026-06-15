--!strict

local Config = {
	Interaction = {
		interactTag = "Interactable",
		interactAttribute = "Interactable",
		itemTypeAttribute = "ItemType",
		weaponIdAttribute = "WeaponId",
		draggableAttribute = "Draggable",
		heldByAttribute = "ItemHeldBy",
	},
	CollisionGroups = {
		character = "ItemCharacters",
		heldObject = "HeldItems",
	},
	Validation = {
		maxEquipDistance = 12,
		maxDragStartDistance = 16,
		maxAimDeviationDegrees = 20,
	},
	Drag = {
		holdDistance = 5,
		minHoldDistance = 3,
		maxHoldDistance = 10,
		scrollStep = 0.75,
		enableInspect = false,
		rotateSensitivity = 0.006,
		maxHoldMass = 5000,
		serverDistanceTolerance = 1.5,
		leashGracePeriod = 0.75,
		positionResponsiveness = 40,
		orientationResponsiveness = 35,
		maxVelocity = 65,
		maxAngularVelocity = 20,
		positionForceMultiplier = 45,
		orientationTorqueMultiplier = 35,
		flingVelocityMultiplier = 1.15,
		dropImpulseSpeed = 45,
	},
	Viewmodel = {
		baseOffset = CFrame.new(0.6, -0.8, -1.2),
		swayAmount = 0.03,
		swaySpeed = 9,
		bobAmount = 0.05,
		bobSpeed = 9,
		kickbackDistance = 0.08,
	},
	Weapon = {
		serverRayLengthPadding = 4,
		defaultReloadDuration = 1.4,
	},
	Input = {
		equipKey = Enum.KeyCode.E,
		reloadKey = Enum.KeyCode.R,
		dragButton = Enum.UserInputType.MouseButton1,
	},
	RemotesFolderName = "ItemSystemRemotes",
	ForceFirstPerson = true,
}

return Config
