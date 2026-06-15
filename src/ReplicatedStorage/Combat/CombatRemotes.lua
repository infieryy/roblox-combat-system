local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatRemotes = {}

CombatRemotes.FOLDER_NAME = "CombatRemotes"
CombatRemotes.EVENTS = {
	DragAction = "DragAction",
	EquipWeapon = "EquipWeapon",
	UnequipWeapon = "UnequipWeapon",
	FireWeapon = "FireWeapon",
	ReloadWeapon = "ReloadWeapon",
	WeaponState = "WeaponState",
}

local function assertValidEvent(eventName: string)
	for _, knownName in CombatRemotes.EVENTS do
		if knownName == eventName then
			return
		end
	end

	error(("Unknown combat remote event '%s'"):format(eventName))
end

function CombatRemotes.getFolder(createIfMissing: boolean?): Folder
	local folder = ReplicatedStorage:FindFirstChild(CombatRemotes.FOLDER_NAME)
	if folder and not folder:IsA("Folder") then
		error(("Instance '%s' exists but is not a Folder"):format(CombatRemotes.FOLDER_NAME))
	end

	if not folder and createIfMissing and RunService:IsServer() then
		local created = Instance.new("Folder")
		created.Name = CombatRemotes.FOLDER_NAME
		created.Parent = ReplicatedStorage
		folder = created
	end

	if not folder then
		folder = ReplicatedStorage:WaitForChild(CombatRemotes.FOLDER_NAME) :: Folder
	end

	return folder :: Folder
end

function CombatRemotes.getEvent(eventName: string, createIfMissing: boolean?): RemoteEvent
	assertValidEvent(eventName)

	local folder = CombatRemotes.getFolder(createIfMissing)
	local event = folder:FindFirstChild(eventName)

	if event and not event:IsA("RemoteEvent") then
		error(("Instance '%s' exists but is not a RemoteEvent"):format(eventName))
	end

	if not event and createIfMissing and RunService:IsServer() then
		local created = Instance.new("RemoteEvent")
		created.Name = eventName
		created.Parent = folder
		event = created
	end

	if not event then
		event = folder:WaitForChild(eventName) :: RemoteEvent
	end

	return event :: RemoteEvent
end

return CombatRemotes
