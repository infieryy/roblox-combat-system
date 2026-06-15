--!strict
--[[
	HoldState (ModuleScript)
	------------------------
	A tiny shared client-side state bridge between the pickup ("dragging") system
	and the combat (weapon / viewmodel) system. It exists so the two systems can
	stay completely decoupled — neither LocalScript requires the other — while
	still coordinating the one piece of state they must agree on:

	  * Holding  : the player is currently carrying a picked-up object.
	  * Rotating : the player is inspecting the held object (holding R).

	The PickupController is the sole writer; the WeaponController and
	ViewmodelController are readers. Readers can also subscribe to be notified the
	instant the state flips, so the weapon can be holstered the very frame a
	pickup is granted (and re-equipped the frame it is dropped).
]]

export type State = {
	holding: boolean,
	rotating: boolean,
}

type Listener = (state: State) -> ()

local HoldState = {}

local state: State = {
	holding = false,
	rotating = false,
}

local listeners: { Listener } = {}

local function notify()
	-- Pass a shallow copy so listeners cannot mutate the canonical state.
	local snapshot: State = { holding = state.holding, rotating = state.rotating }
	for _, listener in listeners do
		task.spawn(listener, snapshot)
	end
end

-- True while the player is carrying a picked-up object.
function HoldState.isHolding(): boolean
	return state.holding
end

-- True while the player is inspecting/rotating the held object (holding R).
function HoldState.isRotating(): boolean
	return state.rotating
end

-- Writer API (PickupController only).
function HoldState.setHolding(value: boolean)
	if state.holding == value then
		return
	end
	state.holding = value
	if not value then
		-- Dropping always ends inspection.
		state.rotating = false
	end
	notify()
end

function HoldState.setRotating(value: boolean)
	-- Rotation only ever makes sense while holding.
	local resolved = value and state.holding
	if state.rotating == resolved then
		return
	end
	state.rotating = resolved
	notify()
end

-- Subscribe to state changes. Returns an unsubscribe function.
function HoldState.subscribe(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

return HoldState
