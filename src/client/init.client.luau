--!strict
-- Client entry point (init.client.luau → StarterPlayerScripts.Client)
-- Starts all client controllers in dependency order.
-- RemotesClient is required by each sibling module directly; no need to pass it explicitly.

-- Load sibling modules.
local ViewmodelController    = require(script.ViewmodelController)
local DragController         = require(script.DragController)
local WeaponController       = require(script.WeaponController)
local InteractionController  = require(script.InteractionController)

-- -------------------------------------------------------------------------
-- Start order matters:
--   1. ViewmodelController — owns LockFirstPerson + exposes getMuzzlePosition/playFireKick.
--   2. DragController      — sets up RenderStep binding and network listeners.
--   3. WeaponController    — needs ViewmodelController API; sets up HUD and input.
--   4. InteractionController — routes input, needs DragController.isDragging().
-- -------------------------------------------------------------------------

ViewmodelController.start()
DragController.start()
WeaponController.start(ViewmodelController)
InteractionController.start(DragController)
