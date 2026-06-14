--!strict
--[[
	Remotes
	-------
	Lazily creates (on the server) or waits for (on the client) the network
	objects used by the pickup system, returning them as a typed table.

	  PickupRequest  (RemoteEvent)            client -> server : ask to grab
	  DropRequest    (RemoteEvent)            client -> server : ask to drop
	  UpdateGoal     (UnreliableRemoteEvent)  client -> server : stream goal
	  HoldStarted    (RemoteEvent)            server -> client : grab confirmed
	  HoldEnded      (RemoteEvent)            server -> client : object released

	`UpdateGoal` is *unreliable* on purpose: goal frames are sent ~30x/second
	and a dropped packet simply means one stale frame, which the next packet
	corrects. This avoids the ordered-delivery overhead of a normal RemoteEvent.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "PickupSystemRemotes"

local DEFINITIONS: { [string]: string } = {
	PickupRequest = "RemoteEvent",
	DropRequest = "RemoteEvent",
	UpdateGoal = "UnreliableRemoteEvent",
	HoldStarted = "RemoteEvent",
	HoldEnded = "RemoteEvent",
}

export type Remotes = {
	PickupRequest: RemoteEvent,
	DropRequest: RemoteEvent,
	UpdateGoal: UnreliableRemoteEvent,
	HoldStarted: RemoteEvent,
	HoldEnded: RemoteEvent,
}

local function build(): Remotes
	local remotes: { [string]: Instance } = {}

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end

		for name, className in pairs(DEFINITIONS) do
			local remote = folder:FindFirstChild(name)
			if not remote then
				remote = Instance.new(className)
				remote.Name = name
				remote.Parent = folder
			end
			remotes[name] = remote
		end
	else
		local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
		for name in pairs(DEFINITIONS) do
			remotes[name] = folder:WaitForChild(name)
		end
	end

	return remotes :: any
end

return build()
