--!strict
-- Module: Client-side remote handles for the item system contract.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

export type ClientRemotes = {
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

local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)

local remotes: ClientRemotes = {
	DragStartRequest = folder:WaitForChild("DragStartRequest") :: RemoteEvent,
	DragEndRequest = folder:WaitForChild("DragEndRequest") :: RemoteEvent,
	DragGranted = folder:WaitForChild("DragGranted") :: RemoteEvent,
	DragEnded = folder:WaitForChild("DragEnded") :: RemoteEvent,
	EquipRequest = folder:WaitForChild("EquipRequest") :: RemoteEvent,
	EquipResult = folder:WaitForChild("EquipResult") :: RemoteEvent,
	UnequipRequest = folder:WaitForChild("UnequipRequest") :: RemoteEvent,
	HoldStateChanged = folder:WaitForChild("HoldStateChanged") :: RemoteEvent,
	FireRequest = folder:WaitForChild("FireRequest") :: RemoteEvent,
	FireResult = folder:WaitForChild("FireResult") :: RemoteEvent,
	ShotFired = folder:WaitForChild("ShotFired") :: RemoteEvent,
	ReloadRequest = folder:WaitForChild("ReloadRequest") :: RemoteEvent,
	ReloadResult = folder:WaitForChild("ReloadResult") :: RemoteEvent,
}

return remotes
