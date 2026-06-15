--!strict
-- Module: server/init.server
-- Server entry point (BLUEPRINT.md §10.0). Builds the remotes, registers
-- collision groups, starts the services in dependency order, and wires the
-- player/character lifecycle (collision-group assignment + drop-on-death/respawn
-- ported from the consensus build).

local Players = game:GetService("Players")

local Remotes = require(script.Remotes)
local PhysicsAuthority = require(script.PhysicsAuthority)
local PlayerHoldState = require(script.PlayerHoldState)
local AmmoLedger = require(script.AmmoLedger)
local DragService = require(script.DragService)
local EquipService = require(script.EquipService)
local WeaponService = require(script.WeaponService)

-- 1. Doors + physics setup.
local remotes = Remotes.create()
PhysicsAuthority.registerCollisionGroups()

-- 2. Start services in order. DragService and EquipService reference each other
-- (the one-item swap teardown contract); both module tables exist before init,
-- so passing references here is safe.
PlayerHoldState.init(remotes)

DragService.init({
	remotes = remotes,
	holdState = PlayerHoldState,
	physics = PhysicsAuthority,
	equipService = EquipService,
})

EquipService.init({
	remotes = remotes,
	holdState = PlayerHoldState,
	ammo = AmmoLedger,
	dragService = DragService,
})

WeaponService.init({
	remotes = remotes,
	holdState = PlayerHoldState,
	ammo = AmmoLedger,
})

-- 3. Lifecycle wiring (ported behaviour: respawn invalidates any hold).
local function onCharacterAdded(player: Player, character: Model)
	-- A respawn drops whatever was held (prop rig or equipped weapon).
	DragService.dropPlayer(player)
	EquipService.dropPlayer(player)
	PlayerHoldState.clear(player)

	PhysicsAuthority.assignCharacterToGroup(character)

	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			DragService.dropPlayer(player)
			EquipService.dropPlayer(player)
			PlayerHoldState.clear(player)
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
	DragService.cleanupPlayer(player)
	EquipService.cleanupPlayer(player)
	WeaponService.cleanupPlayer(player)
	AmmoLedger.clearPlayer(player)
	PlayerHoldState.clear(player)
end)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
