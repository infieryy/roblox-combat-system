--!strict
--[[
    RemotesClient  (client)
    -----------------------
    Waits for the ItemSystemRemotes folder created by server/Remotes and returns
    a typed handle to all RemoteEvents. All client modules require this module
    and never call WaitForChild on remotes directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config") :: ModuleScript)

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

local function waitForAll(): RemoteSet
    local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
    local function w(name: string): RemoteEvent
        return folder:WaitForChild(name) :: RemoteEvent
    end
    return {
        DragStartRequest = w("DragStartRequest"),
        DragEndRequest   = w("DragEndRequest"),
        DragGranted      = w("DragGranted"),
        DragEnded        = w("DragEnded"),
        EquipRequest     = w("EquipRequest"),
        EquipResult      = w("EquipResult"),
        UnequipRequest   = w("UnequipRequest"),
        HoldStateChanged = w("HoldStateChanged"),
        FireRequest      = w("FireRequest"),
        FireResult       = w("FireResult"),
        ShotFired        = w("ShotFired"),
        ReloadRequest    = w("ReloadRequest"),
        ReloadResult     = w("ReloadResult"),
    }
end

local RemotesClient = {}

function RemotesClient.get(): RemoteSet
    if not cached then
        cached = waitForAll()
    end
    return cached :: RemoteSet
end

return RemotesClient
