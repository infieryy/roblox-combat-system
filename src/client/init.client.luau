--!strict
-- Module: Client bootstrap for item system controllers.

local RemotesClient = require(script.Parent.RemotesClient)
local ViewmodelController = require(script.Parent.ViewmodelController)
local DragController = require(script.Parent.DragController)
local WeaponController = require(script.Parent.WeaponController)
local InteractionController = require(script.Parent.InteractionController)

ViewmodelController.start(RemotesClient)
DragController.start(RemotesClient)
WeaponController.start(RemotesClient, ViewmodelController)
InteractionController.start(RemotesClient, DragController)
