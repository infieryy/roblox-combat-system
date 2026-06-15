--!strict
-- Module: client/init.client (becomes StarterPlayerScripts.Client)
-- Waits for the remotes, builds the shared client context, and starts the
-- controllers. ViewmodelController starts first so it owns the first-person lock
-- before targeting/firing begins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local RemotesClient = require(script:WaitForChild("RemotesClient"))
local ViewmodelController = require(script:WaitForChild("ViewmodelController"))
local InteractionController = require(script:WaitForChild("InteractionController"))
local DragController = require(script:WaitForChild("DragController"))
local WeaponController = require(script:WaitForChild("WeaponController"))

local remotes = RemotesClient.get()

local ctx = {
	remotes = remotes,
	config = Config,
	geometry = GeometryUtil,
	itemRegistry = ItemRegistry,
	viewmodel = ViewmodelController,
	interaction = InteractionController,
	drag = DragController,
	weapon = WeaponController,
}

ViewmodelController.start(ctx)
DragController.start(ctx)
InteractionController.start(ctx)
WeaponController.start(ctx)
