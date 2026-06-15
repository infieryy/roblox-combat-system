--!strict
-- Server entry point (init.server.luau → ServerScriptService.Server)
-- Requires and initialises every server module in dependency order.
-- Wires cross-service teardown functions to resolve the circular dependency
-- between DragService (needs to force-unequip) and EquipService (needs to force-release).
-- Handles PlayerAdded / CharacterAdded lifecycle for the whole system.

local Players = game:GetService("Players")

-- Load all server modules (siblings of this script in Server folder).
local Remotes          = require(script.Remotes)
local PhysicsAuthority = require(script.PhysicsAuthority)
local PlayerHoldState  = require(script.PlayerHoldState)
local AmmoLedger       = require(script.AmmoLedger)
local DragService      = require(script.DragService)
local EquipService     = require(script.EquipService)
local WeaponService    = require(script.WeaponService)

-- -------------------------------------------------------------------------
-- 1. Collision groups (must happen before any session can form)
-- -------------------------------------------------------------------------

PhysicsAuthority.registerCollisionGroups()

-- -------------------------------------------------------------------------
-- 2. PlayerHoldState (needs HoldStateChanged remote reference)
-- -------------------------------------------------------------------------

PlayerHoldState.init(Remotes.HoldStateChanged)

-- -------------------------------------------------------------------------
-- 3. Services (in dependency order; cross-service teardown resolved here)
-- -------------------------------------------------------------------------

-- DragService calls forceUnequip when a weapon holder grabs a prop.
-- EquipService calls forceRelease when a prop holder equips a weapon.
-- These closures break the mutual dependency without either module requiring the other.

DragService.init(
	Remotes,
	PhysicsAuthority,
	PlayerHoldState,
	function(player: Player, weaponInstance: Instance?)
		EquipService.forceUnequip(player, weaponInstance)
	end
)

EquipService.init(
	Remotes,
	PhysicsAuthority,
	PlayerHoldState,
	AmmoLedger,
	function(player: Player)
		DragService.forceRelease(player)
	end
)

WeaponService.init(Remotes, PlayerHoldState, AmmoLedger)

-- -------------------------------------------------------------------------
-- 4. Player lifecycle
-- -------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	-- Assign the new character's parts to the PickupCharacters collision group
	-- so held objects pass through the player cleanly.
	PhysicsAuthority.assignCharacterToGroup(character)

	-- Drop anything held on respawn (server also enforces via leash, but
	-- this gives an immediate clean drop so the client hears DragEnded).
	DragService.onCharacterAdded(player, character)

	-- Auto-unequip weapon on death (the weapon is released back to the world).
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			local state = PlayerHoldState.get(player)
			if state.kind == "Weapon" then
				-- Pass the weapon instance before clearing state so forceUnequip can detach it.
				EquipService.forceUnequip(player, state.instance)
				PlayerHoldState.clear(player)
			elseif state.kind == "Prop" then
				DragService.forceRelease(player)
				PlayerHoldState.clear(player)
			end
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

local function onPlayerRemoving(player: Player)
	-- Full teardown: release any held object/weapon, free memory in every module.
	local state = PlayerHoldState.get(player)
	DragService.forceRelease(player)
	EquipService.forceUnequip(player, state.instance)
	PlayerHoldState.removePlayer(player)
	AmmoLedger.clearPlayer(player)
	WeaponService.clearPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players who joined before this script ran (Studio play-test scenario).
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
