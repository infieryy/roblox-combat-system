--!strict
--[[
	Interactable
	------------
	Shared logic for deciding whether something can be picked up. Both the client
	(for the crosshair prompt) and the server (for validation) use the exact same
	rules, so there is never a mismatch between what the player is shown and what
	the server will allow.

	An instance qualifies if it OR one of its ancestors (up to Workspace) has the
	configured CollectionService tag or the configured boolean attribute.
]]

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Config)

local Interactable = {}

-- Returns true if this specific instance is flagged as interactable.
function Interactable.isFlagged(instance: Instance): boolean
	if CollectionService:HasTag(instance, Config.Tag) then
		return true
	end
	return instance:GetAttribute(Config.Attribute) == true
end

-- Walks up from `hit` looking for the first interactable ancestor (or itself).
-- Returns nil if nothing in the chain is interactable.
function Interactable.resolve(hit: Instance?): Instance?
	local current = hit
	while current and current ~= workspace do
		if Interactable.isFlagged(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

return Interactable
