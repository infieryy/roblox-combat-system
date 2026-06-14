--!strict

--[[
	Creates and exposes RemoteEvents for the pickup system.
	Required by both client and server controllers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local function getOrCreateFolder(): Folder
	local pickupFolder = ReplicatedStorage:FindFirstChild("PickupSystem")
	if not pickupFolder then
		pickupFolder = Instance.new("Folder")
		pickupFolder.Name = "PickupSystem"
		pickupFolder.Parent = ReplicatedStorage
	end

	return pickupFolder :: Folder
end

local function getOrCreateRemote(name: string): RemoteEvent
	local folder = getOrCreateFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

function Remotes.getPickupRequest(): RemoteEvent
	return getOrCreateRemote("PickupRequest")
end

function Remotes.getDropRequest(): RemoteEvent
	return getOrCreateRemote("DropRequest")
end

function Remotes.getRotateUpdate(): RemoteEvent
	return getOrCreateRemote("RotateUpdate")
end

function Remotes.getHoldState(): RemoteEvent
	return getOrCreateRemote("HoldState")
end

return Remotes
