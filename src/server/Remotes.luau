--!strict
-- Module: Remotes  (server side)
-- Creates the ItemSystemRemotes folder in ReplicatedStorage and every RemoteEvent
-- defined in the blueprint §8 contracts.
-- Called once from init.server.luau before any service starts.
-- Returns a typed table used by every server module — never ad-hoc WaitForChild.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

-- -------------------------------------------------------------------------
-- Remote names (frozen contract — do not rename without a BREAKING CONTRACT PR)
-- -------------------------------------------------------------------------
local REMOTE_NAMES = {
	-- Drag / prop (ported + renamed from consensus PickupRequest/PickupGranted/…)
	"DragStartRequest",   -- C→S  prop: Instance
	"DragEndRequest",     -- C→S  (none)
	"DragGranted",        -- S→C  prop, primaryPart, alignPosition, alignOrientation
	"DragEnded",          -- S→C  prop?

	-- Weapon / equip (new)
	"EquipRequest",       -- C→S  weaponInstance: Instance
	"EquipResult",        -- S→C  ok: boolean, weaponId?: string, ammo?: number
	"UnequipRequest",     -- C→S  (none)
	"HoldStateChanged",   -- S→C  kind: "Weapon"|"Prop"|"None", instance?: Instance
	"FireRequest",        -- C→S  origin: Vector3, direction: Vector3, clientShotId: number
	"FireResult",         -- S→C  clientShotId: number, ok: boolean, ammo: number, hitPosition?: Vector3
	"ShotFired",          -- S→All  shooter: Player, origin: Vector3, hitPosition: Vector3
	"ReloadRequest",      -- C→S  (none)
	"ReloadResult",       -- S→C  ok: boolean, ammo: number
}

export type RemoteSet = {
	DragStartRequest: RemoteEvent,
	DragEndRequest: RemoteEvent,
	DragGranted: RemoteEvent,
	DragEnded: RemoteEvent,
	EquipRequest: RemoteEvent,
	EquipResult: RemoteEvent,
	UnequipRequest: RemoteEvent,
	HoldStateChanged: RemoteEvent,
	FireRequest: RemoteEvent,
	FireResult: RemoteEvent,
	ShotFired: RemoteEvent,
	ReloadRequest: RemoteEvent,
	ReloadResult: RemoteEvent,
}

local function buildRemotes(): RemoteSet
	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	assert(folder, "remotes folder creation failed")

	for _, name in REMOTE_NAMES do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	-- Return a typed table so every module uses explicit names, never magic strings.
	return {
		DragStartRequest  = folder:WaitForChild("DragStartRequest")  :: RemoteEvent,
		DragEndRequest    = folder:WaitForChild("DragEndRequest")    :: RemoteEvent,
		DragGranted       = folder:WaitForChild("DragGranted")       :: RemoteEvent,
		DragEnded         = folder:WaitForChild("DragEnded")         :: RemoteEvent,
		EquipRequest      = folder:WaitForChild("EquipRequest")      :: RemoteEvent,
		EquipResult       = folder:WaitForChild("EquipResult")       :: RemoteEvent,
		UnequipRequest    = folder:WaitForChild("UnequipRequest")    :: RemoteEvent,
		HoldStateChanged  = folder:WaitForChild("HoldStateChanged")  :: RemoteEvent,
		FireRequest       = folder:WaitForChild("FireRequest")       :: RemoteEvent,
		FireResult        = folder:WaitForChild("FireResult")        :: RemoteEvent,
		ShotFired         = folder:WaitForChild("ShotFired")         :: RemoteEvent,
		ReloadRequest     = folder:WaitForChild("ReloadRequest")     :: RemoteEvent,
		ReloadResult      = folder:WaitForChild("ReloadResult")      :: RemoteEvent,
	} :: RemoteSet
end

return buildRemotes()
