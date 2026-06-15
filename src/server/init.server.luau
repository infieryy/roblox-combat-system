--!strict

local Players = game:GetService("Players")

local Remotes = require(script:WaitForChild("Remotes"))
local PhysicsAuthority = require(script:WaitForChild("PhysicsAuthority"))
local PlayerHoldState = require(script:WaitForChild("PlayerHoldState"))
local AmmoLedger = require(script:WaitForChild("AmmoLedger"))
local DragService = require(script:WaitForChild("DragService"))
local EquipService = require(script:WaitForChild("EquipService"))
local WeaponService = require(script:WaitForChild("WeaponService"))

local remotes = Remotes.get()

PhysicsAuthority.registerCollisionGroups()
AmmoLedger.start()
PlayerHoldState.start(remotes)

DragService.setEquipService(EquipService)
EquipService.setDragService(DragService)

DragService.start(remotes)
EquipService.start(remotes)
WeaponService.start(remotes)

local function onCharacterAdded(character: Model)
	PhysicsAuthority.assignCharacterCollisionGroup(character)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		DragService.forceRelease(player, "character_removed")
		EquipService.forceUnequip(player, "character_removed", true)
		PlayerHoldState.clear(player)
	end)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	DragService.forceRelease(player, "left")
	EquipService.forceUnequip(player, "left", true)
	AmmoLedger.cleanup(player)
	PlayerHoldState.cleanup(player)
end)
