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

local cached: RemoteMap? = nil

local RemotesClient = {}

function RemotesClient.get(): RemoteMap
	if cached then
		return cached
	end

	local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
	local map = {
		DragStartRequest = folder:WaitForChild("DragStartRequest"),
		DragEndRequest = folder:WaitForChild("DragEndRequest"),
		DragGranted = folder:WaitForChild("DragGranted"),
		DragEnded = folder:WaitForChild("DragEnded"),
		EquipRequest = folder:WaitForChild("EquipRequest"),
		EquipResult = folder:WaitForChild("EquipResult"),
		FireRequest = folder:WaitForChild("FireRequest"),
		FireResult = folder:WaitForChild("FireResult"),
		ReloadRequest = folder:WaitForChild("ReloadRequest"),
		HoldStateChanged = folder:WaitForChild("HoldStateChanged"),
	}

	cached = (map :: any) :: RemoteMap
	return cached
end

return RemotesClient
