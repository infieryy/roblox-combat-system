--!nonstrict
--[[
	PickupServer  (Script)
	-----------------------------------------------------------------------------
	Thin entry point. All logic lives in the sibling `PickupService` ModuleScript
	so it stays unit-test friendly and reusable. This script just boots it.
--]]

local PickupService = require(script.Parent:WaitForChild("PickupService"))

PickupService.start()
