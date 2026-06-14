--[[
	PickupServer (bootstrap Script)
	------------------------------------------------------------------
	Thin entry point. All behaviour lives in the PickupService
	ModuleScript so the logic stays testable and reusable; this Script's
	only job is to start it once the game runs.
]]

local PickupService = require(script:WaitForChild("PickupService"))

PickupService.Start()
