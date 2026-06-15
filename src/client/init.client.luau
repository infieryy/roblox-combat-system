--!strict
-- Module: init.client
-- Starts all client controllers in dependency order.

local RemotesClient = require(script.RemotesClient)
local ViewmodelController = require(script.ViewmodelController)
local InteractionController = require(script.InteractionController)
local DragController = require(script.DragController)
local WeaponController = require(script.WeaponController)

local remotes = RemotesClient.waitForRemotes()

ViewmodelController.start()
InteractionController.start(remotes)
DragController.start(remotes)
WeaponController.start(remotes)
