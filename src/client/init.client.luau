--!strict
-- init.client.luau  (LocalScript → StarterPlayerScripts.Client)
-- Bootstrap: waits for remotes, constructs all client controllers in dependency order,
-- then starts them. Blueprint §11.0.
--
-- Dependency order:
--   RemotesClient (waits for server folder)
--   → ViewmodelController (owns first-person lock + arms render)
--   → DragController (rig steering, mouse-delta for sway)
--   → InteractionController (raycast routing: weapon E / prop LMB)
--   → WeaponController (fire, reload, ammo HUD)

local RemotesClient         = require(script.RemotesClient)
local ViewmodelController   = require(script.ViewmodelController)
local DragController        = require(script.DragController)
local InteractionController = require(script.InteractionController)
local WeaponController      = require(script.WeaponController)

local remotes = RemotesClient

local viewmodel     = ViewmodelController.new()
local drag          = DragController.new(remotes)
local interaction   = InteractionController.new(remotes, drag)
local weapon        = WeaponController.new(remotes, drag, viewmodel, interaction)

-- Start in order: viewmodel must run first so playFireKick() works when weapon fires.
viewmodel:start()
drag:start()        -- no-op render binding; wired inside .new()
interaction:start()
weapon:start()

-- Cleanup on script destroy (character respawn replaces LocalScript).
script.Destroying:Connect(function()
	weapon:destroy()
	interaction:destroy()
	drag:destroy()
	viewmodel:destroy()
end)
