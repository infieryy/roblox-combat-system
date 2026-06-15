--!strict
--[[
	Remotes  (server/Remotes.luau → ServerScriptService.Server.Remotes)
	--------------------------------------------------------------------
	Called ONCE from init.server.luau to create the ItemSystemRemotes folder
	and all RemoteEvents in it, then returns typed handles.

	The client-side counterpart (client/RemotesClient.luau) waits for this
	folder via WaitForChild and returns the same typed handles.

	ALL remotes are defined here. No other module may create its own remotes.
	Adding a new remote requires updating BOTH this file and RemotesClient.luau
	in the same PR, with "BREAKING CONTRACT" in the PR title.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote table type (frozen contract — payload shapes documented inline)
-- ─────────────────────────────────────────────────────────────────────────────

export type RemoteSet = {
	-- Drag / prop  ────────────────────────────────────────────────────────────
	-- C→S  player mouse-pressed a draggable prop
	DragStartRequest:  RemoteEvent,
	-- C→S  mouse released
	DragEndRequest:    RemoteEvent,
	-- S→C  drag granted; client steers the provided constraint refs each frame
	DragGranted:       RemoteEvent,
	-- S→C  drag ended (by server or client)
	DragEnded:         RemoteEvent,

	-- Weapon / equip  ─────────────────────────────────────────────────────────
	-- C→S  player pressed E on a weapon
	EquipRequest:      RemoteEvent,
	-- S→C  equip result:  ok, weaponId?, ammo?
	EquipResult:       RemoteEvent,
	-- C→S  player wants to put the gun away
	UnequipRequest:    RemoteEvent,
	-- S→C  authoritative hold change (overrides client prediction)
	HoldStateChanged:  RemoteEvent,

	-- Shooting  ───────────────────────────────────────────────────────────────
	-- C→S  fire intent:  origin, direction, clientShotId
	FireRequest:       RemoteEvent,
	-- S→C  fire result:  clientShotId, ok, ammo, hitPosition?
	FireResult:        RemoteEvent,
	-- S→All  broadcast for tracers/impacts:  shooter, origin, hitPosition
	ShotFired:         RemoteEvent,
	-- C→S  reload
	ReloadRequest:     RemoteEvent,
	-- S→C  reload result:  ok, ammo
	ReloadResult:      RemoteEvent,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────────────────────────────────────

local EVENT_NAMES: { string } = {
	"DragStartRequest", "DragEndRequest", "DragGranted", "DragEnded",
	"EquipRequest", "EquipResult", "UnequipRequest", "HoldStateChanged",
	"FireRequest", "FireResult", "ShotFired", "ReloadRequest", "ReloadResult",
}

local Remotes = {}
local cached: RemoteSet? = nil

function Remotes.build(): RemoteSet
	if cached then
		return cached
	end

	local folder = ReplicatedStorage:FindFirstChild(Config.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end

	local set: { [string]: RemoteEvent } = {}
	for _, name in EVENT_NAMES do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			set[name] = existing :: RemoteEvent
		else
			local event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
			set[name] = event
		end
	end

	cached = (set :: any) :: RemoteSet
	return cached :: RemoteSet
end

-- Convenience: return the already-built set (must call build() first).
function Remotes.get(): RemoteSet
	assert(cached, "[Remotes] get() called before build(). Call Remotes.build() in init.server first.")
	return cached :: RemoteSet
end

return Remotes
