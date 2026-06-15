--!strict
-- Module: client/RemotesClient
-- Waits for the runtime ItemSystemRemotes folder created by the server and
-- returns typed handles (BLUEPRINT.md §11.1). Controllers access remotes only
-- through this module, never via ad-hoc WaitForChild.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

export type RemotesTable = {
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

local cached: RemotesTable? = nil

function RemotesClient.get(): RemotesTable
	if cached then
		return cached
	end
	local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
	local result: { [string]: any } = {}
	for _, name in REMOTE_NAMES do
		result[name] = folder:WaitForChild(name)
	end
	cached = result :: any
	return cached :: RemotesTable
end

return RemotesClient
