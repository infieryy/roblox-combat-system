--!strict
--[[
	init.client  (client/init.client.luau → StarterPlayerScripts.Client)
	----------------------------------------------------------------------
	Bootstrap LocalScript. Waits for the remotes folder (ensuring the server
	has started) then starts each controller in the correct dependency order.

	Start order matters:
	  1. RemotesClient.get() — resolves all remote handles.
	  2. ViewmodelController — owns LockFirstPerson; starts the render loop.
	  3. DragController     — registers DragGranted / DragEnded listeners.
	  4. WeaponController   — registers EquipResult / FireResult listeners.
	  5. InteractionController — starts the raycast loop; calls DragController.

	All controllers are started on the same frame; task.spawn is only used to
	avoid blocking the main thread on WaitForChild chains inside each module.
]]

-- Kick off remote resolution FIRST so controllers don't race on WaitForChild.
local RemotesClient = require(script.RemotesClient)
RemotesClient.get()  -- blocks until ItemSystemRemotes exists

-- Controllers (children of this LocalScript via Rojo src/client/).
local ViewmodelController    = require(script.ViewmodelController)
local DragController         = require(script.DragController)
local WeaponController       = require(script.WeaponController)
local InteractionController  = require(script.InteractionController)

ViewmodelController.start()
DragController.start()
WeaponController.start()
InteractionController.start()
