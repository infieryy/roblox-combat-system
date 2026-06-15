--!strict
-- Module: server/init.server.luau

local Players = game:GetService("Players")

local Remotes = require(script.Remotes)
local PhysicsAuthority = require(script.PhysicsAuthority)
local PlayerHoldState = require(script.PlayerHoldState)
local AmmoLedger = require(script.AmmoLedger)
local DragService = require(script.DragService)
local EquipService = require(script.EquipService)
local WeaponService = require(script.WeaponService)

local remotes = Remotes.build()

PlayerHoldState.configure({
	HoldStateChanged = remotes.HoldStateChanged,
})

DragService.configure({
	remotes = remotes,
	equipService = EquipService,
})

EquipService.configure({
	remotes = remotes,
	dragService = DragService,
})

WeaponService.configure(remotes)

PhysicsAuthority.registerCollisionGroups()

DragService.start()
EquipService.start()
WeaponService.start()

local function onCharacterAdded(player: Player, character: Model)
	PhysicsAuthority.assignCharacterToGroup(character)
	DragService.onCharacterAdded(player)
	EquipService.onCharacterAdded(player)

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
