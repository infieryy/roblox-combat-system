--!strict
-- Module: init.client
-- Boots all client controllers.

local RemotesClient = require(script.RemotesClient)
local ViewmodelController = require(script.ViewmodelController)
local InteractionController = require(script.InteractionController)
local DragController = require(script.DragController)
local WeaponController = require(script.WeaponController)

local remotes = RemotesClient.waitForRemotes()

ViewmodelController.start(remotes)
InteractionController.start(remotes)
DragController.start(remotes)
WeaponController.start(remotes)
