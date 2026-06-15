--!strict
-- Module: server/init.server (becomes ServerScriptService.Server)
-- Integration owner: builds remotes, registers collision groups, wires the
-- shared dependency context, and starts every service in dependency order.
-- Also owns player/character lifecycle (collision group assignment, drop on
-- death/respawn, cleanup on leave).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry"))

local Remotes = require(script:WaitForChild("Remotes"))
local PhysicsAuthority = require(script:WaitForChild("PhysicsAuthority"))
local PlayerHoldState = require(script:WaitForChild("PlayerHoldState"))
local AmmoLedger = require(script:WaitForChild("AmmoLedger"))
local DragService = require(script:WaitForChild("DragService"))
local EquipService = require(script:WaitForChild("EquipService"))
local WeaponService = require(script:WaitForChild("WeaponService"))

-- Build the doors and the physics environment first.
local remotes = Remotes.build()
PhysicsAuthority.registerCollisionGroups()

-- The shared dependency context every service reads from. Populated fully before
-- any .start() runs, so cross-service references (drag<->equip teardown) resolve.
local ctx = {
	remotes = remotes,
	config = Config,
	geometry = GeometryUtil,
	itemRegistry = ItemRegistry,
	physics = PhysicsAuthority,
	holdState = PlayerHoldState,
	ammo = AmmoLedger,
	drag = DragService,
	equip = EquipService,
	weapon = WeaponService,
}

-- Start in dependency order.
AmmoLedger.start(ctx)
PlayerHoldState.start(ctx)
DragService.start(ctx)
EquipService.start(ctx)
WeaponService.start(ctx)

----------------------------------------------------------------------
-- Lifecycle.
----------------------------------------------------------------------

local function dropEverything(player: Player)
	DragService.drop(player, false)
	EquipService.unequip(player)
end

local function onCharacterAdded(player: Player, character: Model)
	-- A respawn invalidates any current hold.
	dropEverything(player)
	PhysicsAuthority.assignCharacterToGroup(character)

	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			dropEverything(player)
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
	-- Services do their own per-player teardown via PlayerRemoving; here we just
	-- drop the authoritative records.
	AmmoLedger.clearPlayer(player)
	PlayerHoldState.remove(player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
