--!strict
-- Module: client/init.client
-- Client entry point (BLUEPRINT.md §11.0). Resolves the remotes then starts the
-- controllers. ViewmodelController starts first so it owns the first-person lock
-- before the interaction/weapon controllers reference it.

local RemotesClient = require(script.RemotesClient)
local ViewmodelController = require(script.ViewmodelController)
local InteractionController = require(script.InteractionController)
local DragController = require(script.DragController)
local WeaponController = require(script.WeaponController)

local remotes = RemotesClient.get()

ViewmodelController.start(remotes)
DragController.start(remotes)
WeaponController.start(remotes)
InteractionController.start(remotes)
