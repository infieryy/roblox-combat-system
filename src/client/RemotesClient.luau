--!strict
--[[
	RemotesClient  (client/RemotesClient.luau → StarterPlayerScripts.Client.RemotesClient)
	------------------------------------------------------------------------------------------
	Waits for the ItemSystemRemotes folder created by server/Remotes.luau and
	returns typed handles. Cached on first call so all controllers share the
	same instances without any extra WaitForChild overhead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- Mirrors server/Remotes.RemoteSet (must stay in sync).
export type RemoteSet = {
	DragStartRequest:  RemoteEvent,
	DragEndRequest:    RemoteEvent,
	DragGranted:       RemoteEvent,
	DragEnded:         RemoteEvent,
	EquipRequest:      RemoteEvent,
	EquipResult:       RemoteEvent,
	UnequipRequest:    RemoteEvent,
	HoldStateChanged:  RemoteEvent,
	FireRequest:       RemoteEvent,
	FireResult:        RemoteEvent,
	ShotFired:         RemoteEvent,
	ReloadRequest:     RemoteEvent,
	ReloadResult:      RemoteEvent,
}

local EVENT_NAMES: { string } = {
	"DragStartRequest", "DragEndRequest", "DragGranted", "DragEnded",
	"EquipRequest", "EquipResult", "UnequipRequest", "HoldStateChanged",
	"FireRequest", "FireResult", "ShotFired", "ReloadRequest", "ReloadResult",
}

local RemotesClient = {}
local cached: RemoteSet? = nil

function RemotesClient.get(): RemoteSet
	if cached then
		return cached
	end

	local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
	local set: { [string]: RemoteEvent } = {}
	for _, name in EVENT_NAMES do
		set[name] = folder:WaitForChild(name) :: RemoteEvent
	end

	cached = (set :: any) :: RemoteSet
	return cached :: RemoteSet
end

return RemotesClient
