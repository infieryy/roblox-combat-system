--!strict
-- Module: Creates and returns the runtime RemoteEvent contract.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

export type RemoteBundle = {
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

local function ensureRemote(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function create(): RemoteBundle
	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	assert(folder and folder:IsA("Folder"), "Failed to create remotes folder")

	local remotes: RemoteBundle = {
		folder = folder,
		DragStartRequest = ensureRemote(folder, "DragStartRequest"),
		DragEndRequest = ensureRemote(folder, "DragEndRequest"),
		DragGranted = ensureRemote(folder, "DragGranted"),
		DragEnded = ensureRemote(folder, "DragEnded"),
		EquipRequest = ensureRemote(folder, "EquipRequest"),
		EquipResult = ensureRemote(folder, "EquipResult"),
		UnequipRequest = ensureRemote(folder, "UnequipRequest"),
		HoldStateChanged = ensureRemote(folder, "HoldStateChanged"),
		FireRequest = ensureRemote(folder, "FireRequest"),
		FireResult = ensureRemote(folder, "FireResult"),
		ShotFired = ensureRemote(folder, "ShotFired"),
		ReloadRequest = ensureRemote(folder, "ReloadRequest"),
		ReloadResult = ensureRemote(folder, "ReloadResult"),
	}

	return remotes
end

return {
	create = create,
}
