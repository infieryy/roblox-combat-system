--!strict
--[[
	Main (Server Script)
	--------------------
	Thin entry point. All logic lives in the PickupService ModuleScript so it can
	be unit-tested / reused; this script just boots it.
]]

local PickupService = require(script.Parent:WaitForChild("PickupService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

PickupService.start()
-- Started after PickupService so the combat layer can query hold state safely.
WeaponService.start()
