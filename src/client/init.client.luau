--!strict
-- Module: client/init.client.luau

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local RemotesClient = require(script.RemotesClient)
local ViewmodelController = require(script.ViewmodelController)
local InteractionController = require(script.InteractionController)
local DragController = require(script.DragController)
local WeaponController = require(script.WeaponController)

local remotes = RemotesClient.waitForRemotes()

ViewmodelController.configure(remotes)
InteractionController.configure(remotes)
DragController.configure(remotes)
WeaponController.configure(remotes)

ViewmodelController.start()
InteractionController.start()
DragController.start()
WeaponController.start()

RunService:BindToRenderStep("ItemSystemInteraction", Enum.RenderPriority.Camera.Value, function()
	InteractionController.onRenderStep()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	InteractionController.onInputBegan(input, gameProcessed)
	WeaponController.onInputBegan(input, gameProcessed)
end)

UserInputService.InputEnded:Connect(function(input)
	DragController.onInputEnded(input)
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	DragController.onInputChanged(input, gameProcessed)
end)
