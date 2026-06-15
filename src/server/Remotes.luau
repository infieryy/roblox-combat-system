--!strict
-- Module: Remotes  (server-side)
-- Creates the ItemSystemRemotes folder in ReplicatedStorage at startup and
-- exposes typed references to every RemoteEvent defined in BLUEPRINT §8.
-- The client counterpart (RemotesClient) waits for this folder.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- -------------------------------------------------------------------------
-- Internal helpers
-- -------------------------------------------------------------------------

local function ensureFolder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemote(name: string, parent: Instance): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

-- -------------------------------------------------------------------------
-- Build
-- -------------------------------------------------------------------------

local folder = ensureFolder(Config.RemotesFolderName, ReplicatedStorage)

local Remotes = {
	-- Drag / prop  (C→S and S→C, ported from consensus; renamed per blueprint §8)
	DragStartRequest  = ensureRemote("DragStartRequest",  folder), -- C→S: Instance (prop)
	DragEndRequest    = ensureRemote("DragEndRequest",    folder), -- C→S: (none)
	DragGranted       = ensureRemote("DragGranted",       folder), -- S→C: prop, primaryPart, alignPosition, alignOrientation
	DragEnded         = ensureRemote("DragEnded",         folder), -- S→C: prop?

	-- Weapon equip  (new)
	EquipRequest      = ensureRemote("EquipRequest",      folder), -- C→S: Instance (weapon)
	EquipResult       = ensureRemote("EquipResult",       folder), -- S→C: ok, weaponId?, ammo?
	UnequipRequest    = ensureRemote("UnequipRequest",    folder), -- C→S: (none)

	-- Authoritative hold state broadcast  (new; server sends unsolicited)
	HoldStateChanged  = ensureRemote("HoldStateChanged",  folder), -- S→C: kind, instance?

	-- Shooting  (new)
	FireRequest       = ensureRemote("FireRequest",       folder), -- C→S: origin, direction, clientShotId
	FireResult        = ensureRemote("FireResult",        folder), -- S→C: clientShotId, ok, ammo, hitPosition?
	ShotFired         = ensureRemote("ShotFired",         folder), -- S→AllClients: shooter, origin, hitPosition

	-- Reload  (new)
	ReloadRequest     = ensureRemote("ReloadRequest",     folder), -- C→S: (none)
	ReloadResult      = ensureRemote("ReloadResult",      folder), -- S→C: ok, ammo
}

return Remotes
