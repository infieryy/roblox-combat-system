--!nonstrict
--[[
	Net
	-----------------------------------------------------------------------------
	Tiny, dependency-free RemoteEvent factory shared by the client and server.

	* On the SERVER it lazily creates a folder of RemoteEvents in
	  ReplicatedStorage (idempotent -- safe to require from many scripts).
	* On the CLIENT it simply waits for that folder to replicate.

	Usage:
		local Net = require(ReplicatedStorage.Pickup.Net)
		Net.RequestPickup:FireServer(target)        -- client
		Net.PickupGranted:FireClient(player, ...)    -- server
--]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "PickupRemotes"

-- Logical name -> RemoteEvent. The same set exists on both sides.
local EVENT_NAMES = {
	-- Client -> Server
	"RequestPickup", -- (target: Instance)
	"RequestDrop", -- ()
	-- Server -> Client
	"PickupGranted", -- (root, primaryPart, alignPosition, alignOrientation)
	"PickupEnded", -- (reason: string?)
}

local function getFolder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		for _, name in EVENT_NAMES do
			if not folder:FindFirstChild(name) then
				local remote = Instance.new("RemoteEvent")
				remote.Name = name
				remote.Parent = folder
			end
		end
		return folder
	else
		return ReplicatedStorage:WaitForChild(FOLDER_NAME, 30) :: Folder
	end
end

local folder = getFolder()

local Net = {}

for _, name in EVENT_NAMES do
	Net[name] = folder:WaitForChild(name)
end

return Net
