--!strict
--[[
    InteractionController  (client)
    --------------------------------
    Owns all player interaction input and routes it to the right subsystem.
    Ported from the consensus FirstPersonPickupClient targeting + highlight
    logic, extended with item-type routing per BLUEPRINT.md §11.2.

    Per-frame raycast from camera centre:
      • Weapon → show "E to Equip" prompt + highlight.
      • Prop    → show "Hold [LMB] to Grab" prompt + highlight (no E prompt).
      • None    → clear prompt / highlight.

    Input routing:
      • E   → if facing Weapon → WeaponController.sendEquipRequest(weapon)
              → if weapon equipped  → WeaponController.sendUnequipRequest()
      • Q   → WeaponController.sendUnequipRequest()  (put gun away)
      • LMB → if weapon equipped → WeaponController.attemptFire()
              else if facing Prop → DragController.beginDrag(prop)
      • LMB released → DragController.endDrag()

    The controller also reacts to HoldStateChanged to keep the HUD consistent
    (e.g. showing "drop" prompt while dragging).
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Config       = require(Shared:WaitForChild("Config")       :: ModuleScript)
local ItemRegistry = require(Shared:WaitForChild("ItemRegistry") :: ModuleScript)

local RemotesClient      = require(script.Parent.RemotesClient)
local DragController     = require(script.Parent.DragController)
local WeaponController   = require(script.Parent.WeaponController)

local localPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local targetObject: Instance? = nil
local character: Model? = localPlayer.Character

-- ---------------------------------------------------------------------------
-- Raycast filter (rebuilt whenever character or hold changes)
-- ---------------------------------------------------------------------------
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function refreshRaycastFilter()
    local filter: { Instance } = {}
    if character then table.insert(filter, character) end
    raycastParams.FilterDescendantsInstances = filter
end

-- ---------------------------------------------------------------------------
-- UI: reticle, highlight, prompt
-- ---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "InteractionUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = localPlayer:WaitForChild("PlayerGui")

local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(6, 6)
reticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
reticle.BackgroundTransparency = 0.35
reticle.BorderSizePixel = 0
local reticleCorner = Instance.new("UICorner")
reticleCorner.CornerRadius = UDim.new(1, 0)
reticleCorner.Parent = reticle
reticle.Parent = gui

local prompt = Instance.new("TextLabel")
prompt.Name = "Prompt"
prompt.AnchorPoint = Vector2.new(0.5, 1)
prompt.Position = UDim2.fromScale(0.5, 0.82)
prompt.Size = UDim2.fromOffset(480, 28)
prompt.BackgroundTransparency = 1
prompt.Font = Enum.Font.GothamMedium
prompt.TextSize = 18
prompt.TextColor3 = Color3.fromRGB(255, 255, 255)
prompt.TextStrokeTransparency = 0.5
prompt.Text = ""
prompt.Visible = false
prompt.Parent = gui

local highlight = Instance.new("Highlight")
highlight.Name = "InteractionHighlight"
highlight.FillTransparency = 0.85
highlight.OutlineTransparency = 0
highlight.FillColor = Color3.fromRGB(255, 255, 255)
highlight.OutlineColor = Color3.fromRGB(255, 220, 120)
highlight.Enabled = false
highlight.Adornee = nil
highlight.Parent = gui

local function setPrompt(text: string?)
    if text and text ~= "" then
        prompt.Text = text
        prompt.Visible = true
    else
        prompt.Visible = false
    end
end

local function setHighlight(object: Instance?)
    if object then
        highlight.Adornee = object
        highlight.Enabled = true
    else
        highlight.Adornee = nil
        highlight.Enabled = false
    end
end

-- ---------------------------------------------------------------------------
-- Targeting
-- ---------------------------------------------------------------------------
-- Walk up from a hit instance to the nearest classified interactable.
local function resolveInteractable(hit: Instance?): Instance?
    local node: Instance? = hit
    while node and node ~= Workspace do
        local kind = ItemRegistry.classify(node)
        if kind ~= "None" then
            return node
        end
        node = (node :: Instance).Parent
    end
    return nil
end

local function setTarget(object: Instance?)
    targetObject = object
    if object then
        setHighlight(object)
        local kind = ItemRegistry.classify(object)
        if kind == "Weapon" then
            if WeaponController.isEquipped() then
                setPrompt("[E] Unequip   •   [Q] Put Away")
            else
                setPrompt("[E] Equip")
            end
        elseif kind == "Prop" then
            if DragController.isDragging() then
                setPrompt("[Release LMB] Drop   •   Scroll: Distance")
            else
                setPrompt("[Hold LMB] Grab")
            end
        end
    else
        setHighlight(nil)
        if DragController.isDragging() then
            setPrompt("[Release LMB] Drop   •   Scroll: Distance")
        elseif WeaponController.isEquipped() then
            setPrompt("[LMB] Fire   •   [R] Reload   •   [Q] Holster")
        else
            setPrompt(nil)
        end
    end
end

local function updateTargeting()
    local cam = Workspace.CurrentCamera
    if not cam then return end

    refreshRaycastFilter()
    local origin    = cam.CFrame.Position
    local direction = cam.CFrame.LookVector * Config.Drag.maxPickupDistance

    local result = Workspace:Raycast(origin, direction, raycastParams)
    local found: Instance? = nil

    if result then
        local resolved = resolveInteractable(result.Instance)
        -- Skip objects already held by someone.
        if resolved and resolved:GetAttribute(Config.HeldByAttribute) == nil then
            found = resolved
        end
    end

    if found ~= targetObject then
        setTarget(found)
    end
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------
local connections: { RBXScriptConnection } = {}

local function bindInput()
    table.insert(connections,
        UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
            if gameProcessed then return end

            -- LMB: route to weapon or drag.
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                if WeaponController.isEquipped() then
                    WeaponController.attemptFire()
                elseif targetObject and ItemRegistry.isDraggable(targetObject) then
                    DragController.beginDrag(targetObject)
                end
                return
            end

            -- E key: equip/unequip a weapon, or do nothing for a prop.
            if input.KeyCode == Enum.KeyCode.E then
                if targetObject then
                    local kind = ItemRegistry.classify(targetObject)
                    if kind == "Weapon" then
                        if WeaponController.isEquipped() then
                            WeaponController.sendUnequipRequest()
                        else
                            WeaponController.sendEquipRequest(targetObject)
                        end
                    end
                elseif WeaponController.isEquipped() then
                    WeaponController.sendUnequipRequest()
                end
                return
            end

            -- Q key: put gun away / holster.
            if input.KeyCode == Enum.KeyCode.Q then
                if WeaponController.isEquipped() then
                    WeaponController.sendUnequipRequest()
                end
                return
            end
        end)
    )

    -- LMB released: end drag.
    table.insert(connections,
        UserInputService.InputEnded:Connect(function(input: InputObject)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                if DragController.isDragging() then
                    DragController.endDrag()
                    setTarget(targetObject) -- refresh prompt
                end
            end
        end)
    )
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function start()
    local R = RemotesClient.get()

    -- Update prompt text when hold state changes.
    table.insert(connections,
        R.HoldStateChanged.OnClientEvent:Connect(function(_kind: string, _instance: unknown)
            setTarget(targetObject)
        end)
    )

    -- Character lifecycle.
    local function onCharacter(char: Model)
        character = char
        refreshRaycastFilter()
    end
    localPlayer.CharacterAdded:Connect(onCharacter)
    if localPlayer.Character then
        onCharacter(localPlayer.Character)
    end

    -- Per-frame targeting (after default camera update).
    -- BindToRenderStep does not return a connection; UnbindFromRenderStep in destroy().
    RunService:BindToRenderStep(
        "InteractionControllerUpdate",
        Enum.RenderPriority.Camera.Value + 1,
        updateTargeting
    )

    bindInput()
end

local InteractionController = {}

function InteractionController.start()
    start()
end

function InteractionController.destroy()
    pcall(RunService.UnbindFromRenderStep, RunService, "InteractionControllerUpdate")
    for _, c in connections do c:Disconnect() end
    table.clear(connections)
    if gui and gui.Parent then gui:Destroy() end
end

InteractionController.start()

return InteractionController
