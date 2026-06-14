--!nonstrict
--[[
	PickupConfig
	-----------------------------------------------------------------------------
	Central, single-source-of-truth tuning for the First-Person Pickup &
	Inspection system. Every value here is shared between the client and the
	server so that the predicted (client) behaviour and the authoritative
	(server) behaviour can never drift apart.

	Tweak values here only -- never hard-code magic numbers in the controllers.
--]]

local PickupConfig = {}

--------------------------------------------------------------------------------
-- Interaction detection
--------------------------------------------------------------------------------

-- An object becomes pickup-able if EITHER:
--   * it (or an ancestor Model) carries this CollectionService tag, OR
--   * it (or an ancestor Model) has this attribute set to `true`.
PickupConfig.InteractTag = "Interactable"
PickupConfig.InteractAttribute = "Interactable"

-- Attribute written onto a held object so other systems (and re-entrancy
-- checks) can tell at a glance who currently owns it.
PickupConfig.HeldByAttribute = "PickupHeldBy"

--------------------------------------------------------------------------------
-- Distances (studs)
--------------------------------------------------------------------------------

-- How far the client raycast reaches when searching for something to grab.
PickupConfig.MaxPickupDistance = 12

-- Extra slack the server allows on top of `MaxPickupDistance` when validating
-- a pickup request. Accounts for latency between the client raycast and the
-- request arriving on the server. Keeps the check strict but not exploitable.
PickupConfig.ServerDistanceTolerance = 4

-- Distance in front of the camera where the *centre* of the held object hovers.
PickupConfig.HoldDistance = 4

--------------------------------------------------------------------------------
-- Mass / safety limits
--------------------------------------------------------------------------------

-- Reject objects whose total assembly mass exceeds this (studs^3-ish units).
-- Set to 0 to disable the limit entirely.
PickupConfig.MaxHoldMass = 0

--------------------------------------------------------------------------------
-- Constraint tuning (AlignPosition / AlignOrientation)
--------------------------------------------------------------------------------

-- Higher = snappier follow, lower = floatier. 200 is rigid-ish, 20 is dreamy.
PickupConfig.PositionResponsiveness = 55
PickupConfig.OrientationResponsiveness = 55

-- Force / torque ceilings. With self-collisions disabled these can be large
-- without flinging the player. They are *finite* on purpose (never math.huge)
-- so a stuck object yields against a wall instead of exploding.
PickupConfig.MaxForce = 1e6
PickupConfig.MaxTorque = 1e6

-- Top speed the object may travel while being dragged toward the goal.
PickupConfig.MaxVelocity = 200

--------------------------------------------------------------------------------
-- Inspection (hold-R-and-move-mouse) tuning
--------------------------------------------------------------------------------

-- Radians of object rotation per pixel of mouse movement.
PickupConfig.RotateSensitivity = 0.0125

--------------------------------------------------------------------------------
-- Collision groups
--------------------------------------------------------------------------------

-- Held objects are moved into `HeldCollisionGroup`, which is configured to NOT
-- collide with `CharacterCollisionGroup`. This stops a held object from
-- shoving its holder around while still colliding with the world (walls,
-- floors, props in the Default group).
PickupConfig.CharacterCollisionGroup = "PickupCharacters"
PickupConfig.HeldCollisionGroup = "PickupHeldObjects"

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

PickupConfig.PickupKey = Enum.KeyCode.E
PickupConfig.RotateKey = Enum.KeyCode.R
PickupConfig.GamepadPickupKey = Enum.KeyCode.ButtonR1
PickupConfig.GamepadRotateKey = Enum.KeyCode.ButtonL1

--------------------------------------------------------------------------------
-- Misc
--------------------------------------------------------------------------------

-- Force the local player into a locked first-person view on join.
PickupConfig.ForceFirstPerson = true

return PickupConfig
