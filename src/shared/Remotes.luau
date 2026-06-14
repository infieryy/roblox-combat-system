--!strict
--[[
	Remotes
	-------
	Lazily creates (server) or waits for (client) the RemoteEvents used by the
	pickup system. Centralising this here means the controllers never have to
	worry about ordering or about a missing instance.

	Replication design:
	  PickupRequest  (client -> server) : ask to pick up a target instance
	  PickupGranted  (server -> client) : confirmation + references to use
	  DropRequest    (client -> server) : ask to drop the held object
	  DropGranted    (server -> client) : confirmation the object was released

	Rotation is intentionally NOT a remote. Because the client becomes the
	network owner of the held assembly, it can drive the AlignOrientation goal
	locally with zero per-frame traffic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "PickupRemotes"
local EVENT_NAMES = {
	"PickupRequest",
	"PickupGranted",
	"DropRequest",
	"DropGranted",
}

export type RemoteSet = {
	PickupRequest: RemoteEvent,
	PickupGranted: RemoteEvent,
	DropRequest: RemoteEvent,
	DropGranted: RemoteEvent,
}

local Remotes = {}

local cached: RemoteSet? = nil

local function buildOnServer(): RemoteSet
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	local set = {}
	for _, name in EVENT_NAMES do
		local event = folder:FindFirstChild(name)
		if not event then
			event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
		end
		set[name] = event
	end
	return (set :: any) :: RemoteSet
end

local function waitOnClient(): RemoteSet
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	local set = {}
	for _, name in EVENT_NAMES do
		set[name] = folder:WaitForChild(name)
	end
	return (set :: any) :: RemoteSet
end

-- Returns the shared RemoteEvent set, building it on the server or waiting for
-- it on the client. The result is cached for subsequent calls.
function Remotes.get(): RemoteSet
	if cached then
		return cached
	end

	local set: RemoteSet
	if RunService:IsServer() then
		set = buildOnServer()
	else
		set = waitOnClient()
	end

	cached = set
	return set
end

return Remotes
