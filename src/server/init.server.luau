--!strict
--[[
    init.server  (ServerScriptService.Server)
    -----------------------------------------
    Entry point for all server-side systems. Execution order matters:

      1. Remotes   — creates the ItemSystemRemotes folder so clients can find events.
      2. PhysicsAuthority — registers collision groups early (before any character spawns).
      3. AmmoLedger       — pure data; no deps.
      4. PlayerHoldState  — pure state; no deps beyond remotes folder existing.
      5. DragService      — needs PhysicsAuthority + PlayerHoldState.
      6. EquipService     — needs PlayerHoldState + AmmoLedger.
      7. WeaponService    — needs PlayerHoldState + AmmoLedger.
      8. Cross-inject     — DragService.setEquipService + EquipService.setDragService
                           (breaks the circular require at load time).
      9. Wire remotes     — connect OnServerEvent handlers.
     10. Player lifecycle — CharacterAdded collision-group assignment, death/respawn
                           drop, PlayerRemoving cleanup.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------------------
-- 1. Build remotes first so everything that lazy-resolves them works.
------------------------------------------------------------------------
local Remotes = require(script.Remotes)
local R = Remotes.get()  -- creates the folder + all events

------------------------------------------------------------------------
-- 2. Collision groups
------------------------------------------------------------------------
local PhysicsAuthority = require(script.PhysicsAuthority)
PhysicsAuthority.registerCollisionGroups()

------------------------------------------------------------------------
-- 3-7. Services
------------------------------------------------------------------------
local AmmoLedger  = require(script.AmmoLedger)
-- PlayerHoldState sets up its PlayerRemoving handler at module load time.
-- Services each require it directly; we load it here to guarantee ordering.
require(script.PlayerHoldState)
local DragService  = require(script.DragService)
local EquipService = require(script.EquipService)
local WeaponService = require(script.WeaponService)

------------------------------------------------------------------------
-- 8. Cross-inject to break circular dependency between Drag ↔ Equip.
------------------------------------------------------------------------
DragService.setEquipService(EquipService)
EquipService.setDragService(DragService)

------------------------------------------------------------------------
-- 9. Start background loops
------------------------------------------------------------------------
DragService.start()  -- leash anti-cheat loop

------------------------------------------------------------------------
-- 10. Wire RemoteEvent handlers
------------------------------------------------------------------------
R.DragStartRequest.OnServerEvent:Connect(function(player, prop)
    DragService.onDragStart(player, prop)
end)

R.DragEndRequest.OnServerEvent:Connect(function(player)
    DragService.onDragEnd(player)
end)

R.EquipRequest.OnServerEvent:Connect(function(player, weapon)
    EquipService.onEquipRequest(player, weapon)
end)

R.UnequipRequest.OnServerEvent:Connect(function(player)
    EquipService.onUnequipRequest(player)
end)

R.FireRequest.OnServerEvent:Connect(function(player, origin, direction, clientShotId)
    WeaponService.onFireRequest(player, origin, direction, clientShotId)
end)

R.ReloadRequest.OnServerEvent:Connect(function(player)
    WeaponService.onReloadRequest(player)
end)

------------------------------------------------------------------------
-- 11. Player lifecycle
------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
    -- Respawn always drops whatever was being held or equipped.
    DragService.onDragEnd(player)
    EquipService.forceUnequip(player)
    AmmoLedger.clearPlayer(player)

    -- Assign the character's parts to the characters collision group.
    PhysicsAuthority.assignCharacterToGroup(character)

    -- Drop on death.
    local humanoid = character:WaitForChild("Humanoid", 5)
    if humanoid and humanoid:IsA("Humanoid") then
        (humanoid :: Humanoid).Died:Connect(function()
            DragService.onDragEnd(player)
            EquipService.forceUnequip(player)
        end)
    end
end

local function onPlayerAdded(player: Player)
    if player.Character then
        task.spawn(onCharacterAdded, player, player.Character)
    end
    player.CharacterAdded:Connect(function(character)
        onCharacterAdded(player, character)
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
    DragService.onDragEnd(player)
    EquipService.forceUnequip(player)
    AmmoLedger.clearPlayer(player)
end)

-- Handle players who were already in the server when this script started.
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end
