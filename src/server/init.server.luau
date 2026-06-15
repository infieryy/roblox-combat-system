--!strict
-- Module: init.server
-- Boots remotes, physics groups, and all authoritative services.

local Players = game:GetService("Players")

local PhysicsAuthority = require(script.PhysicsAuthority)
local Remotes = require(script.Remotes)
local AmmoLedger = require(script.AmmoLedger)
local PlayerHoldState = require(script.PlayerHoldState)
local DragService = require(script.DragService)
local EquipService = require(script.EquipService)
local WeaponService = require(script.WeaponService)

local remotes = Remotes.build()

PhysicsAuthority.registerCollisionGroups()

PlayerHoldState.start(remotes)

DragService.configure({
	equipService = EquipService,
})

DragService.start(remotes)
EquipService.start(remotes)
WeaponService.start(remotes)

local function onCharacterAdded(player: Player, character: Model)
	DragService.onCharacterAdded(player)
	EquipService.onCharacterAdded(player)
	PhysicsAuthority.assignCharacterToGroup(character)

	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			DragService.onCharacterAdded(player)
			EquipService.onCharacterAdded(player)
		end)
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	DragService.onPlayerRemoving(player)
	EquipService.onPlayerRemoving(player)
	WeaponService.onPlayerRemoving(player)
	AmmoLedger.clearPlayer(player)
	PlayerHoldState.onPlayerRemoving(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
