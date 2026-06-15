--!strict
-- Module: server/Remotes
-- Creates the single runtime RemoteEvent folder and every event in THE REMOTES
-- CONTRACT (BLUEPRINT.md §8). The server owns creation; the client waits.
-- No RemoteFunctions are used (avoids client-yield exploits).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

export type RemotesTable = {
	folder: Folder,
	-- Drag / prop (ported from consensus, renamed per §8)
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
	-- Weapon / equip (new)
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

-- Builds (or finds, on hot reload) the folder and all events, returning the
-- typed handle table consumed by every server service.
function Remotes.create(): RemotesTable
	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end

	local result: { [string]: any } = { folder = folder }
	for _, name in REMOTE_NAMES do
		local remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
		result[name] = remote
	end

	return result :: any
end

return Remotes
