local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = Shared:WaitForChild("Net")
local RemoteNames = require(Net:WaitForChild("RemoteNames"))

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotes = {
	EquipWeapon = remotesFolder:WaitForChild(RemoteNames.EquipWeapon),
	FireWeapon = remotesFolder:WaitForChild(RemoteNames.FireWeapon),
	BeginDrag = remotesFolder:WaitForChild(RemoteNames.BeginDrag),
	UpdateDrag = remotesFolder:WaitForChild(RemoteNames.UpdateDrag),
	EndDrag = remotesFolder:WaitForChild(RemoteNames.EndDrag),
}

local controllersFolder = script.Parent:WaitForChild("Controllers")
local DragController = require(controllersFolder:WaitForChild("DragController"))
local ViewmodelController = require(controllersFolder:WaitForChild("ViewmodelController"))
local WeaponController = require(controllersFolder:WaitForChild("WeaponController"))

local dragController = DragController.new(remotes)
local viewmodelController = ViewmodelController.new(dragController)
local weaponController = WeaponController.new(remotes, dragController, viewmodelController)

weaponController:Start()

script.Destroying:Connect(function()
	weaponController:Destroy()
	viewmodelController:Destroy()
	dragController:Destroy()
end)
