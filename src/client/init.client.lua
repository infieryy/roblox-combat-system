--[[
	PickupClient (bootstrap LocalScript)
	------------------------------------------------------------------
	Thin entry point. The first-person camera, targeting raycast, input
	handling and hold-rig driving all live in the PickupController
	ModuleScript; this LocalScript just starts it.
]]

local PickupController = require(script:WaitForChild("PickupController"))

PickupController.Start()
