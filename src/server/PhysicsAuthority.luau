--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GeometryUtil = require(Shared:WaitForChild("GeometryUtil"))

local PhysicsAuthority = {}

function PhysicsAuthority.registerCollisionGroups()
	GeometryUtil.ensureCollisionGroups(Config.CollisionGroups.character, Config.CollisionGroups.heldObject)
end

function PhysicsAuthority.assignCharacterCollisionGroup(character: Model)
	local function assignPart(instance: Instance)
		if instance:IsA("BasePart") then
			instance.CollisionGroup = Config.CollisionGroups.character
		end
	end

	for _, descendant in character:GetDescendants() do
		assignPart(descendant)
	end
	character.DescendantAdded:Connect(assignPart)
end

return PhysicsAuthority
