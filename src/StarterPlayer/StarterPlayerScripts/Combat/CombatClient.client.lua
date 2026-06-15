local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatFolder = ReplicatedStorage:WaitForChild("Combat")
local CombatRemotes = require(CombatFolder:WaitForChild("CombatRemotes"))

local DragController = require(script.Parent:WaitForChild("DragController"))
local ViewmodelController = require(script.Parent:WaitForChild("ViewmodelController"))
local WeaponController = require(script.Parent:WaitForChild("WeaponController"))

local remotes = {
	dragAction = CombatRemotes.getEvent(CombatRemotes.EVENTS.DragAction),
	equipWeapon = CombatRemotes.getEvent(CombatRemotes.EVENTS.EquipWeapon),
	unequipWeapon = CombatRemotes.getEvent(CombatRemotes.EVENTS.UnequipWeapon),
	fireWeapon = CombatRemotes.getEvent(CombatRemotes.EVENTS.FireWeapon),
	reloadWeapon = CombatRemotes.getEvent(CombatRemotes.EVENTS.ReloadWeapon),
	weaponState = CombatRemotes.getEvent(CombatRemotes.EVENTS.WeaponState),
}

local dragController = DragController.new(remotes.dragAction)
local viewmodelController = ViewmodelController.new()
local weaponController = WeaponController.new(remotes, viewmodelController, dragController)

weaponController:start()
