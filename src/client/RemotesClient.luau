--!strict
-- Module: RemotesClient
-- Waits for the ItemSystemRemotes folder created by server/Remotes.luau and
-- returns a typed handle table. Every client module uses this — never ad-hoc WaitForChild.
-- Module-level WaitForChild calls block until the server has created the folder and events,
-- which is safe because this runs in a LocalScript after the server has initialised.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)

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

local Remotes: RemoteSet = {
	DragStartRequest  = folder:WaitForChild("DragStartRequest")  :: RemoteEvent,
	DragEndRequest    = folder:WaitForChild("DragEndRequest")    :: RemoteEvent,
	DragGranted       = folder:WaitForChild("DragGranted")       :: RemoteEvent,
	DragEnded         = folder:WaitForChild("DragEnded")         :: RemoteEvent,
	EquipRequest      = folder:WaitForChild("EquipRequest")      :: RemoteEvent,
	EquipResult       = folder:WaitForChild("EquipResult")       :: RemoteEvent,
	UnequipRequest    = folder:WaitForChild("UnequipRequest")    :: RemoteEvent,
	HoldStateChanged  = folder:WaitForChild("HoldStateChanged")  :: RemoteEvent,
	FireRequest       = folder:WaitForChild("FireRequest")       :: RemoteEvent,
	FireResult        = folder:WaitForChild("FireResult")        :: RemoteEvent,
	ShotFired         = folder:WaitForChild("ShotFired")         :: RemoteEvent,
	ReloadRequest     = folder:WaitForChild("ReloadRequest")     :: RemoteEvent,
	ReloadResult      = folder:WaitForChild("ReloadResult")      :: RemoteEvent,
}

return Remotes
