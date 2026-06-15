--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

export type RemoteMap = {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
	EquipRequest: RemoteEvent,
	EquipResult: RemoteEvent,
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ReloadRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
}

local REMOTE_NAMES = {
	"DragStartRequest",
	"DragEndRequest",
	"DragGranted",
	"DragEnded",
	"EquipRequest",
	"EquipResult",
	"FireRequest",
	"FireResult",
	"ReloadRequest",
	"HoldStateChanged",
}

local cached: RemoteMap? = nil

local Remotes = {}

function Remotes.get(): RemoteMap
	if cached then
		return cached
	end

	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end

	local map: { [string]: RemoteEvent } = {}
	for _, name in REMOTE_NAMES do
		local remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
		map[name] = remote :: RemoteEvent
	end

	cached = (map :: any) :: RemoteMap
	return cached
end

return Remotes
