--!strict
-- Module: Server bootstrap for remotes and all item-system services.

local Players = game:GetService("Players")

local Remotes = require(script.Parent.Remotes)
local PhysicsAuthority = require(script.Parent.PhysicsAuthority)
local PlayerHoldState = require(script.Parent.PlayerHoldState)
local AmmoLedger = require(script.Parent.AmmoLedger)
local DragService = require(script.Parent.DragService)
local EquipService = require(script.Parent.EquipService)
local WeaponService = require(script.Parent.WeaponService)

local remotes = Remotes.create()

PhysicsAuthority.registerCollisionGroups()
PlayerHoldState.start(remotes)
AmmoLedger.start()
DragService.start(remotes)
EquipService.start(remotes, DragService)
DragService.setEquipService(EquipService)
WeaponService.start(remotes, EquipService)

local function onCharacterAdded(player: Player, character: Model)
	DragService.forceRelease(player)
	EquipService.forceUnequip(player)
	PlayerHoldState.clear(player)

	PhysicsAuthority.assignCharacterToGroup(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Connect(function()
			DragService.forceRelease(player)
			EquipService.forceUnequip(player)
			PlayerHoldState.clear(player)
		end)
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	DragService.cleanupPlayer(player)
	EquipService.cleanupPlayer(player)
	WeaponService.cleanupPlayer(player)
	AmmoLedger.clearPlayer(player)
	PlayerHoldState.clearPlayer(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
