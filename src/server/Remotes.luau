--!strict
-- Module: server/Remotes
-- Creates the single runtime RemoteEvent folder (§8 — "the only doors") and
-- returns typed handles. No RemoteFunctions (avoids client-yield exploits).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

export type RemoteSet = {
	-- Drag / prop
	DragStartRequest: RemoteEvent, -- C->S : (prop: Instance)
	DragEndRequest: RemoteEvent, -- C->S : ()
	DragGranted: RemoteEvent, -- S->C : (prop, primaryPart, alignPosition, alignOrientation)
	DragEnded: RemoteEvent, -- S->C : (prop: Instance?)
	-- Weapon / equip
	EquipRequest: RemoteEvent, -- C->S : (weapon: Instance)
	EquipResult: RemoteEvent, -- S->C : (ok, weaponId?, ammo?)
	UnequipRequest: RemoteEvent, -- C->S : ()
	HoldStateChanged: RemoteEvent, -- S->C : (kind, instance?)
	FireRequest: RemoteEvent, -- C->S : (origin, direction, clientShotId)
	FireResult: RemoteEvent, -- S->C : (clientShotId, ok, ammo, hitPosition?)
	ShotFired: RemoteEvent, -- S->Clients : (shooter, origin, hitPosition)
	ReloadRequest: RemoteEvent, -- C->S : ()
	ReloadResult: RemoteEvent, -- S->C : (ok, ammo)
}

local EVENT_NAMES = {
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

local function ensureFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Config.RemotesFolderName
	folder.Parent = ReplicatedStorage
	return folder
end

function Remotes.build(): RemoteSet
	local folder = ensureFolder()

	local handles: { [string]: RemoteEvent } = {}
	for _, name in EVENT_NAMES do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			handles[name] = existing
		else
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
			handles[name] = remote
		end
	end

	return (handles :: any) :: RemoteSet
end

return Remotes
