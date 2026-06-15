--!strict
--[[
	init.server  (server/init.server.luau → ServerScriptService.Server)
	---------------------------------------------------------------------
	Bootstrap script. Starts up all server services in the correct dependency
	order. Everything runs on the server; clients have their own init.client.

	Start order:
	  1. Build RemoteEvents (clients may start waiting as soon as they join).
	  2. Register collision groups.
	  3. Start services (order matters only where one service calls another's
	     stubs at init time; lazy requires handle runtime cross-service calls).
	  4. Wire PlayerAdded / CharacterAdded / PlayerRemoving lifecycle.
]]

local Players = game:GetService("Players")

-- All server modules are children of this script (Rojo src/server → SSS.Server).
local Remotes          = require(script.Remotes)
local PhysicsAuthority = require(script.PhysicsAuthority)
local PlayerHoldState  = require(script.PlayerHoldState)
local AmmoLedger       = require(script.AmmoLedger)
local DragService      = require(script.DragService)
local EquipService     = require(script.EquipService)
local WeaponService    = require(script.WeaponService)

-- ── 1. Build remotes FIRST so clients that join immediately can WaitForChild ─
Remotes.build()

-- ── 2. Collision groups ───────────────────────────────────────────────────────
PhysicsAuthority.registerCollisionGroups()

-- ── 3. Start services ─────────────────────────────────────────────────────────
DragService.start()
EquipService.start()
WeaponService.start()

-- ── 4. Player / Character lifecycle ──────────────────────────────────────────

local function onCharacterAdded(player: Player, character: Model)
	-- Respawn drops any held prop / equipped weapon.
	DragService.onCharacterAdded(player, character)
	EquipService.onCharacterAdded(player)

	-- Assign character parts to the characters collision group.
	PhysicsAuthority.assignCharacterToGroup(character)

	-- Drop-on-death.
	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			DragService.dropOnDeath(player)
			EquipService.onCharacterAdded(player) -- force-unequip on death
		end)
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
end

local function onPlayerRemoving(player: Player)
	DragService.onPlayerRemoving(player)
	EquipService.onPlayerRemoving(player)
	WeaponService.onPlayerRemoving(player)
	AmmoLedger.clearPlayer(player)
	PlayerHoldState.removePlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players that were already in the server when this script ran.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
