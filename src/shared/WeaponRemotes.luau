--!strict
--[[
	WeaponRemotes
	-------------
	Lazily creates (server) or waits for (client) the RemoteEvents used by the
	combat layer. Identical lifecycle pattern to `Remotes` so the controllers
	never worry about ordering or a missing instance.

	Replication design:
	  EquipRequest    (client -> server) : ask to equip a weapon by name
	  EquipGranted    (server -> client) : confirm equip + authoritative ammo
	  UnequipRequest  (client -> server) : ask to holster the current weapon
	  UnequipGranted  (server -> client) : confirm holstered
	  FireRequest     (client -> server) : report a shot (origin, dirs, hits)
	  FireResult      (server -> client) : authoritative ammo + accepted flag
	  HitConfirm      (server -> ALL)    : broadcast a confirmed hit for FX
	  AmmoUpdate      (server -> client) : authoritative ammo after reload, etc.

	Aiming/recoil are NOT remotes — the camera and viewmodel are simulated purely
	on the owning client, so there is zero per-frame remote traffic. The only
	traffic is a small message per shot / equip / reload.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "WeaponRemotes"
local EVENT_NAMES = {
	"EquipRequest",
	"EquipGranted",
	"UnequipRequest",
	"UnequipGranted",
	"FireRequest",
	"FireResult",
	"HitConfirm",
	"AmmoUpdate",
}

export type RemoteSet = {
	EquipRequest: RemoteEvent,
	EquipGranted: RemoteEvent,
	UnequipRequest: RemoteEvent,
	UnequipGranted: RemoteEvent,
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	HitConfirm: RemoteEvent,
	AmmoUpdate: RemoteEvent,
}

local WeaponRemotes = {}

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
function WeaponRemotes.get(): RemoteSet
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

return WeaponRemotes
