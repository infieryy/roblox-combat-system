--!strict
-- Module: Remotes
-- Creates and exposes all ItemSystem RemoteEvents (§8 contract).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

export type RemotesTable = {
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

local Remotes = {}

function Remotes.build(): RemotesTable
	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	assert(folder and folder:IsA("Folder"), "remotes folder")

	for _, name in REMOTE_NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	local remotesTable = {
		folder = folder,
	} :: any

	for _, name in REMOTE_NAMES do
		remotesTable[name] = folder:WaitForChild(name) :: RemoteEvent
	end

	return remotesTable :: RemotesTable
end

return Remotes
