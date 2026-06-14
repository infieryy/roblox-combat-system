--!strict
--[[
	Config
	------------------------------------------------------------------
	Central, shared tuning values for the First-Person Pickup &
	Inspection system. Both the client and server require this module so
	that the rules (distances, keys, force tuning, anti-exploit limits)
	stay perfectly in sync across the network boundary.

	Everything here is data only -- no behaviour -- which keeps the
	system easy to retune without touching gameplay code.
]]

local Config = {}

------------------------------------------------------------------
-- Detection
------------------------------------------------------------------

-- A Model/BasePart is pickable if it carries this CollectionService tag...
Config.InteractTag = "Interactable"

-- ...OR if it has this attribute set to `true`. Either one works, so
-- artists can tag from Studio's Tag Editor or set an attribute on import.
Config.InteractAttribute = "Interactable"

------------------------------------------------------------------
-- Reach / distances (studs)
------------------------------------------------------------------

-- How far the client raycast reaches and the hard cap the server uses
-- when validating a pickup request.
Config.MaxPickupDistance = 12

-- Slack multiplier the server allows when validating the initial pickup
-- distance (accounts for latency between the client's frame and the
-- server processing the request).
Config.ServerDistanceTolerance = 1.5

-- Base distance the held object floats in front of the camera. The real
-- distance is scaled up by the object's bounding radius so large props
-- do not clip into the camera.
Config.HoldDistance = 5
Config.HoldDistancePadding = 1.0
Config.MinHoldDistance = 3
Config.MaxHoldDistance = 9

-- How much one mouse-wheel notch pushes/pulls the held object.
Config.ScrollStep = 1

------------------------------------------------------------------
-- Anti-exploit
------------------------------------------------------------------

-- Reject absurdly heavy assemblies (anti-grief / fling protection).
Config.MaxHoldMass = 5000

-- While an object is held the client owns its physics. The server keeps
-- "leashing" it: if the object stays further than the allowed radius for
-- longer than the grace period, the server force-drops it.
Config.LeashGracePeriod = 0.75

------------------------------------------------------------------
-- AlignPosition tuning (linear drag)
------------------------------------------------------------------

Config.PositionResponsiveness = 35
Config.PositionMaxVelocity = 60
-- MaxForce is computed as: assemblyMass * gravity * PositionForceMultiplier
-- so the *acceleration* applied is consistent regardless of object mass.
Config.PositionForceMultiplier = 50

------------------------------------------------------------------
-- AlignOrientation tuning (rotational drag)
------------------------------------------------------------------

Config.OrientationResponsiveness = 35
Config.OrientationMaxAngularVelocity = 25
-- MaxTorque is computed as: assemblyMass * boundingRadius^2 * multiplier
-- (an approximation of moment of inertia) so spin feel is consistent
-- across small and large props.
Config.OrientationTorqueMultiplier = 40

------------------------------------------------------------------
-- Camera & input
------------------------------------------------------------------

Config.PickupKey = Enum.KeyCode.E
Config.RotateKey = Enum.KeyCode.R

-- Degrees of rotation per pixel of mouse movement.
Config.LookSensitivity = 0.4
Config.RotateSensitivity = 0.6

-- Maximum pitch (look up/down) in degrees.
Config.PitchLimit = 80

-- Eye height above the HumanoidRootPart origin.
Config.EyeOffset = Vector3.new(0, 1.5, 0)

-- Hide the local character so it never blocks the first-person view.
Config.HideCharacterInFirstPerson = true

------------------------------------------------------------------
-- Networking
------------------------------------------------------------------

Config.RemotesFolderName = "PickupRemotes"

------------------------------------------------------------------
-- Demo
------------------------------------------------------------------

-- When true the server spawns a few tagged sample props so you can test
-- the system immediately in an empty place.
Config.SpawnSampleObjects = false

return Config
