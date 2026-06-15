--!strict
-- Module: client/RemotesClient
-- Waits for the runtime RemoteEvent folder the server built and returns typed
-- handles. The only place the client touches the remote folder.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

export type RemoteSet = {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
	EquipRequest: RemoteEvent,
	EquipResult: RemoteEvent,
	UnequipRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ShotFired: RemoteEvent,
	ReloadRequest: RemoteEvent,
	ReloadResult: RemoteEvent,
}

local EVENT_NAMES = {
	"DragStartRequest",
	"DragEndRequest",
	"DragGranted",
	"DragEnded",
	"EquipRequest",
	"EquipResult",
	"UnequipRequest",
	"HoldStateChanged",
	"FireRequest",
	"FireResult",
	"ShotFired",
	"ReloadRequest",
	"ReloadResult",
}

local RemotesClient = {}

function RemotesClient.get(): RemoteSet
	local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
	local handles: { [string]: RemoteEvent } = {}
	for _, name in EVENT_NAMES do
		handles[name] = folder:WaitForChild(name) :: RemoteEvent
	end
	return (handles :: any) :: RemoteSet
end

return RemotesClient
