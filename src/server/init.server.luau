--!strict
-- init.server.luau  (Script → ServerScriptService.Server)
-- Bootstrap: creates remotes, registers collision groups, starts all services,
-- wires player lifecycle, then injects cross-service callbacks.
-- Blueprint §10.0 / §16 Agent 1 (A+C).

local Players = game:GetService("Players")

-- All child ModuleScripts are accessible as direct children of this script.
local Remotes         = require(script.Remotes)
local PhysicsAuthority = require(script.PhysicsAuthority)
local PlayerHoldState  = require(script.PlayerHoldState)
local AmmoLedger       = require(script.AmmoLedger)
local DragService      = require(script.DragService)
local EquipService     = require(script.EquipService)
local WeaponService    = require(script.WeaponService)

-- -------------------------------------------------------------------------
-- 1. Collision groups (must be first so character groups apply at spawn).
-- -------------------------------------------------------------------------
PhysicsAuthority.registerCollisionGroups()

-- -------------------------------------------------------------------------
-- 2. Start services in dependency order.
-- -------------------------------------------------------------------------
PlayerHoldState.start(Remotes.HoldStateChanged)
AmmoLedger.start()

DragService.start({
	Remotes = Remotes,
	PlayerHoldState = PlayerHoldState,
	PhysicsAuthority = PhysicsAuthority,
})

EquipService.start({
	Remotes = Remotes,
	PlayerHoldState = PlayerHoldState,
	AmmoLedger = AmmoLedger,
})

WeaponService.start({
	Remotes = Remotes,
	PlayerHoldState = PlayerHoldState,
	AmmoLedger = AmmoLedger,
})

-- -------------------------------------------------------------------------
-- 3. Wire cross-service teardown callbacks (avoids circular requires).
--    DragService.forceRelease ↔ EquipService.forceUnequip
-- -------------------------------------------------------------------------
DragService.setForceUnequipCallback(function(player: Player)
	EquipService.forceUnequip(player)
end)
EquipService.setForceReleaseCallback(function(player: Player)
	DragService.forceRelease(player)
end)

-- -------------------------------------------------------------------------
-- 4. Player lifecycle.
-- -------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	-- Respawn drops any held prop / unequips any weapon.
	DragService.onCharacterAdded(player)
	EquipService.onCharacterAdded(player)
	PhysicsAuthority.assignCharacterToGroup(character)

	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			DragService.onCharacterAdded(player) -- re-use: drop on death
			EquipService.onCharacterAdded(player)
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

local function onPlayerRemoving(player: Player)
	DragService.onPlayerRemoving(player)
	EquipService.onPlayerRemoving(player)
	WeaponService.onPlayerRemoving(player)
	AmmoLedger.clearPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
