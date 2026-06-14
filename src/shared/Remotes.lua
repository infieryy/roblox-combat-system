--!strict
--[[
	Remotes
	------------------------------------------------------------------
	Lazily creates (server) or waits for (client) the RemoteEvents used by
	the pickup system, returning them as a typed table. Keeping the remote
	names in one place avoids string typos across the network boundary.

	Remotes used:
	  RequestPickup  (C -> S)  client asks to pick up a hit instance
	  RequestDrop    (C -> S)  client asks to drop whatever it holds
	  PickupGranted  (S -> C)  server hands back the live hold rig refs
	  PickupEnded    (S -> C)  server tells the client a hold has ended
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent:WaitForChild("Config"))

local REMOTE_NAMES = { "RequestPickup", "RequestDrop", "PickupGranted", "PickupEnded" }

export type RemoteMap = {
	RequestPickup: RemoteEvent,
	RequestDrop: RemoteEvent,
	PickupGranted: RemoteEvent,
	PickupEnded: RemoteEvent,
}

local Remotes = {}

local cached: RemoteMap? = nil

function Remotes.get(): RemoteMap
	if cached then
		return cached
	end

	local map: { [string]: RemoteEvent } = {}

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = Config.RemotesFolderName
			folder.Parent = ReplicatedStorage
		end
		for _, name in REMOTE_NAMES do
			local remote = folder:FindFirstChild(name)
			if not remote then
				remote = Instance.new("RemoteEvent")
				remote.Name = name
				remote.Parent = folder
			end
			map[name] = remote :: RemoteEvent
		end
	else
		local folder = ReplicatedStorage:WaitForChild(Config.RemotesFolderName)
		for _, name in REMOTE_NAMES do
			map[name] = folder:WaitForChild(name) :: RemoteEvent
		end
	end

	local result: RemoteMap = (map :: any) :: RemoteMap
	cached = result
	return result
end

return Remotes
