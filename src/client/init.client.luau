--!strict
--[[
    init.client  (StarterPlayerScripts.Client)
    ------------------------------------------
    Client entry point. Startup order:

      1. RemotesClient.get()  — blocks until the server's ItemSystemRemotes folder
                                and all events exist. Everything after this is safe.
      2. ViewmodelController  — first-person lock, arms/gun rendering.
      3. WeaponController     — equip/fire/reload logic and ammo HUD.
      4. DragController       — constraint-steering for held props.
      5. InteractionController— targets the world, routes all input; auto-starts.

    Each controller self-registers its own remote listeners and render connections
    inside its start() call. The Destroying event tears everything down cleanly
    on character respawn or game shutdown.
]]

local RemotesClient          = require(script.RemotesClient)
local ViewmodelController    = require(script.ViewmodelController)
local WeaponController       = require(script.WeaponController)
local DragController         = require(script.DragController)
local InteractionController  = require(script.InteractionController)

-- Ensure all RemoteEvents are resolved before any controller tries to use them.
RemotesClient.get()

-- Start subsystems in dependency order.
ViewmodelController.start()
WeaponController.start()
DragController.start()
-- InteractionController auto-starts on require (it builds the UI immediately).

-- Clean up on script destruction (respawn / game shutdown).
script.Destroying:Connect(function()
    InteractionController.destroy()
    DragController.destroy()
    WeaponController.destroy()
    ViewmodelController.destroy()
end)
