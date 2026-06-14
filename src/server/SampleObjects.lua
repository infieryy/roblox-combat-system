--[[
	SampleObjects (optional demo helper)
	------------------------------------------------------------------
	Spawns a handful of tagged, pickable props near the spawn location so
	the system can be tested in an otherwise empty place. Enable it by
	setting Config.SpawnSampleObjects = true.

	In a real project you would instead tag your own Blender imports with
	the "Interactable" CollectionService tag (or set the matching
	attribute) and remove this file.
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("PickupSystem"):WaitForChild("Config"))

local SampleObjects = {}

local function makeProp(name: string, size: Vector3, color: Color3, cframe: CFrame): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CFrame = cframe
	part.Anchored = false
	part.CanCollide = true
	CollectionService:AddTag(part, Config.InteractTag)
	part.Parent = Workspace
	return part
end

function SampleObjects.Spawn()
	local base = CFrame.new(0, 5, -10)
	makeProp("Crate", Vector3.new(3, 3, 3), Color3.fromRGB(160, 110, 60), base * CFrame.new(-5, 0, 0))
	makeProp("Barrel", Vector3.new(2, 4, 2), Color3.fromRGB(90, 90, 100), base * CFrame.new(0, 0, 0))
	makeProp("Plank", Vector3.new(1, 0.5, 6), Color3.fromRGB(200, 170, 120), base * CFrame.new(5, 0, 0))
end

return SampleObjects
