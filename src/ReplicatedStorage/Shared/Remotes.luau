--!strict
--[[
	Central remote registry. Both client and server require this module
	instead of hardcoding paths.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder

return {
	PickupRequest = remotesFolder:WaitForChild("PickupRequest") :: RemoteEvent,
	DropRequest = remotesFolder:WaitForChild("DropRequest") :: RemoteEvent,
	PickupResult = remotesFolder:WaitForChild("PickupResult") :: RemoteEvent,
}
