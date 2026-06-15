--!strict
-- Module: RemotesClient
-- Waits for ItemSystem RemoteEvents on the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

export type RemotesClientTable = {
	folder: Folder,
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

local REMOTE_NAMES = {
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

function RemotesClient.waitForRemotes(): RemotesClientTable
	local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName) :: Folder
	local remotesTable = {
		folder = folder,
	} :: any

	for _, name in REMOTE_NAMES do
		remotesTable[name] = folder:WaitForChild(name) :: RemoteEvent
	end

	return remotesTable :: RemotesClientTable
end

return RemotesClient
