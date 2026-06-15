--!strict

local RemotesClient = require(script:WaitForChild("RemotesClient"))
local DragController = require(script:WaitForChild("DragController"))
local InteractionController = require(script:WaitForChild("InteractionController"))
local ViewmodelController = require(script:WaitForChild("ViewmodelController"))
local WeaponController = require(script:WaitForChild("WeaponController"))

local remotes = RemotesClient.get()

ViewmodelController.start()
DragController.start(remotes)
WeaponController.start(remotes, ViewmodelController, DragController)
InteractionController.start(remotes, DragController)
