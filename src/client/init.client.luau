--!strict
-- Module: init.client
-- Client bootstrap: remotes, controllers, unified input/render loop.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	InteractionController.onInputBegan(input, gameProcessed)
	DragController.onInputBegan(input, gameProcessed)
	WeaponController.onInputBegan(input, gameProcessed)
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	InteractionController.onInputEnded(input, gameProcessed)
	DragController.onInputEnded(input)
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	DragController.onInputChanged(input, gameProcessed)
end)

RunService:BindToRenderStep("ItemSystemUpdate", Enum.RenderPriority.Camera.Value + 1, function(dt)
	ViewmodelController.onRenderStep(dt)
	InteractionController.onRenderStep()
	DragController.onRenderStep()
end)
