local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteNames = require(Shared:WaitForChild("Net"):WaitForChild("RemoteNames"))
local WeaponDefinitions = require(Shared:WaitForChild("Weapons"):WaitForChild("WeaponDefinitions"))
local DragConfig = require(Shared:WaitForChild("Drag"):WaitForChild("DragConfig"))

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local function getOrCreateRemoteEvent(remoteName)
	local existing = remotesFolder:FindFirstChild(remoteName)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = remotesFolder
	return remote
end

local remotes = {
	EquipWeapon = getOrCreateRemoteEvent(RemoteNames.EquipWeapon),
	FireWeapon = getOrCreateRemoteEvent(RemoteNames.FireWeapon),
	BeginDrag = getOrCreateRemoteEvent(RemoteNames.BeginDrag),
	UpdateDrag = getOrCreateRemoteEvent(RemoteNames.UpdateDrag),
	EndDrag = getOrCreateRemoteEvent(RemoteNames.EndDrag),
}

local playerState = {}
local activeDrags = {}

local function getRootPart(player)
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
end

local function isDraggable(part)
	if not part or not part:IsA("BasePart") then
		return false
	end

	return part:GetAttribute("Draggable") == true
		or CollectionService:HasTag(part, DragConfig.draggableTag)
end

local function clearDrag(player)
	local targetPart = activeDrags[player]
	activeDrags[player] = nil
	if targetPart and targetPart:IsA("BasePart") and targetPart:IsDescendantOf(Workspace) then
		pcall(function()
			targetPart:SetNetworkOwnershipAuto()
		end)
	end
end

local function getPlayerWeaponState(player)
	local state = playerState[player]
	if state then
		return state
	end

	state = {
		equippedWeaponId = "rifle",
		lastFireAt = 0,
	}
	playerState[player] = state
	return state
end

local function validateFirePayload(player, weaponId, origin, direction)
	local weaponData = WeaponDefinitions.getWeapon(weaponId)
	if not weaponData then
		return nil
	end

	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return nil
	end

	local rootPart = getRootPart(player)
	if not rootPart then
		return nil
	end

	if (origin - rootPart.Position).Magnitude > 20 then
		return nil
	end

	local unitDirection = direction.Magnitude > 0 and direction.Unit or nil
	if not unitDirection then
		return nil
	end

	return weaponData, unitDirection
end

Players.PlayerAdded:Connect(function(player)
	getPlayerWeaponState(player)
	player.CharacterRemoving:Connect(function()
		clearDrag(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
	clearDrag(player)
end)

remotes.EquipWeapon.OnServerEvent:Connect(function(player, weaponId)
	local weaponData = WeaponDefinitions.getWeapon(weaponId)
	if not weaponData then
		return
	end

	local state = getPlayerWeaponState(player)
	state.equippedWeaponId = weaponId
end)

remotes.FireWeapon.OnServerEvent:Connect(function(player, weaponId, origin, direction)
	local state = getPlayerWeaponState(player)
	if weaponId ~= state.equippedWeaponId then
		return
	end

	local weaponData, unitDirection = validateFirePayload(player, weaponId, origin, direction)
	if not weaponData then
		return
	end

	local now = os.clock()
	if now - state.lastFireAt < weaponData.cooldown then
		return
	end
	state.lastFireAt = now

	local character = player.Character
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = character and { character } or {}

	local rayResult = Workspace:Raycast(origin, unitDirection * weaponData.range, params)
	if not rayResult then
		return
	end

	local hitPart = rayResult.Instance
	local hitModel = hitPart and hitPart:FindFirstAncestorOfClass("Model")
	local humanoid = hitModel and hitModel:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid:TakeDamage(weaponData.damage)
	end
end)

remotes.BeginDrag.OnServerEvent:Connect(function(player, targetPart)
	if not isDraggable(targetPart) then
		return
	end

	local rootPart = getRootPart(player)
	if not rootPart then
		return
	end

	if (targetPart.Position - rootPart.Position).Magnitude > DragConfig.maxGrabDistance then
		return
	end

	if targetPart.Anchored then
		return
	end

	activeDrags[player] = targetPart
	pcall(function()
		targetPart:SetNetworkOwner(nil)
	end)
end)

remotes.UpdateDrag.OnServerEvent:Connect(function(player, desiredPosition)
	if typeof(desiredPosition) ~= "Vector3" then
		return
	end

	local targetPart = activeDrags[player]
	if not targetPart or not targetPart:IsDescendantOf(Workspace) then
		clearDrag(player)
		return
	end

	local rootPart = getRootPart(player)
	if not rootPart then
		clearDrag(player)
		return
	end

	local dragOffset = desiredPosition - rootPart.Position
	local dragDistance = dragOffset.Magnitude
	if dragDistance == 0 then
		return
	end
	local clampedPosition = rootPart.Position + dragOffset.Unit * math.min(dragDistance, DragConfig.maxHoldDistance)

	local rotation = targetPart.CFrame - targetPart.Position
	targetPart.CFrame = CFrame.new(clampedPosition) * rotation
	targetPart.AssemblyLinearVelocity = Vector3.zero
	targetPart.AssemblyAngularVelocity = Vector3.zero
end)

remotes.EndDrag.OnServerEvent:Connect(function(player)
	clearDrag(player)
end)
