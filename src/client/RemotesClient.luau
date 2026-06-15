--!strict
-- Module: RemotesClient  (client-side)
-- Waits for the ItemSystemRemotes folder created by server/Remotes.luau and
-- returns typed references to every RemoteEvent. Blueprint §11.1.
-- All other client modules require this; the WaitForChild calls here mean only
-- ONE module ever blocks on the folder's existence.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)

local RemotesClient = {
	-- Drag / prop
	DragStartRequest = folder:WaitForChild("DragStartRequest") :: RemoteEvent,
	DragEndRequest   = folder:WaitForChild("DragEndRequest")   :: RemoteEvent,
	DragGranted      = folder:WaitForChild("DragGranted")      :: RemoteEvent,
	DragEnded        = folder:WaitForChild("DragEnded")        :: RemoteEvent,

	-- Equip
	EquipRequest     = folder:WaitForChild("EquipRequest")     :: RemoteEvent,
	EquipResult      = folder:WaitForChild("EquipResult")      :: RemoteEvent,
	UnequipRequest   = folder:WaitForChild("UnequipRequest")   :: RemoteEvent,

	-- Hold state broadcast
	HoldStateChanged = folder:WaitForChild("HoldStateChanged") :: RemoteEvent,

	-- Shooting
	FireRequest      = folder:WaitForChild("FireRequest")      :: RemoteEvent,
	FireResult       = folder:WaitForChild("FireResult")       :: RemoteEvent,
	ShotFired        = folder:WaitForChild("ShotFired")        :: RemoteEvent,

	-- Reload
	ReloadRequest    = folder:WaitForChild("ReloadRequest")    :: RemoteEvent,
	ReloadResult     = folder:WaitForChild("ReloadResult")     :: RemoteEvent,
}

return RemotesClient
