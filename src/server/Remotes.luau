--!strict
--[[
    Remotes  (server/Remotes.luau → ServerScriptService.Server.Remotes)
    -----------------------------------------------------------------------
    Creates every RemoteEvent in ReplicatedStorage.ItemSystemRemotes.
    This is the single place all remotes are built; the client waits for
    them via client/RemotesClient.

    THE REMOTES CONTRACT (from BLUEPRINT.md §8) — do not add / rename without
    a BREAKING CONTRACT PR that also updates BLUEPRINT.md.

    Drag / prop:
      DragStartRequest   C→S   (prop: Instance)
      DragEndRequest     C→S   ()
      DragGranted        S→C   (prop, primaryPart, alignPosition, alignOrientation)
      DragEnded          S→C   (prop: Instance?)

    Weapon / equip:
      EquipRequest       C→S   (weaponInstance: Instance)
      EquipResult        S→C   (ok: boolean, weaponId: string?, ammo: number?)
      UnequipRequest     C→S   ()
      HoldStateChanged   S→C   (kind: "Weapon"|"Prop"|"None", instance: Instance?)

    Firing:
      FireRequest        C→S   (origin: Vector3, direction: Vector3, clientShotId: number)
      FireResult         S→C   (clientShotId: number, ok: boolean, ammo: number, hitPosition: Vector3?)
      ShotFired          S→All (shooter: Player, origin: Vector3, hitPosition: Vector3)

    Reload:
      ReloadRequest      C→S   ()
      ReloadResult       S→C   (ok: boolean, ammo: number)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _config = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript
)
local FOLDER_NAME: string = (_config :: any).RemotesFolderName

local EVENT_NAMES: { string } = {
    -- Drag
    "DragStartRequest",
    "DragEndRequest",
    "DragGranted",
    "DragEnded",
    -- Equip
    "EquipRequest",
    "EquipResult",
    "UnequipRequest",
    "HoldStateChanged",
    -- Fire
    "FireRequest",
    "FireResult",
    "ShotFired",
    -- Reload
    "ReloadRequest",
    "ReloadResult",
}

export type RemoteSet = {
    DragStartRequest: RemoteEvent,
    DragEndRequest:   RemoteEvent,
    DragGranted:      RemoteEvent,
    DragEnded:        RemoteEvent,
    EquipRequest:     RemoteEvent,
    EquipResult:      RemoteEvent,
    UnequipRequest:   RemoteEvent,
    HoldStateChanged: RemoteEvent,
    FireRequest:      RemoteEvent,
    FireResult:       RemoteEvent,
    ShotFired:        RemoteEvent,
    ReloadRequest:    RemoteEvent,
    ReloadResult:     RemoteEvent,
}

local cached: RemoteSet? = nil

local function build(): RemoteSet
    local folder: Folder
    local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
    if existing and existing:IsA("Folder") then
        folder = existing :: Folder
    else
        folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = ReplicatedStorage
    end

    local set: { [string]: RemoteEvent } = {}
    for _, name in EVENT_NAMES do
        local event = folder:FindFirstChild(name)
        if not (event and event:IsA("RemoteEvent")) then
            event = Instance.new("RemoteEvent")
            event.Name = name
            event.Parent = folder
        end
        set[name] = event :: RemoteEvent
    end
    return (set :: any) :: RemoteSet
end

local Remotes = {}

function Remotes.get(): RemoteSet
    if not cached then
        cached = build()
    end
    return cached :: RemoteSet
end

return Remotes
