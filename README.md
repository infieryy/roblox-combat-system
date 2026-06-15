# roblox-combat-system

A server-authoritative first-person physics drag + hitscan weapon system for Roblox, built with **Rojo** and **Luau strict mode**.

## Architecture

```
src/
├── shared/                   → ReplicatedStorage.Shared
│   ├── Types.luau            WeaponDef, HoldState, HoldRig type exports
│   ├── Config.luau           All tunable values (single source of truth)
│   ├── GeometryUtil.luau     getBoundingBox, getVisualCenter, getPrimaryPart …
│   └── ItemRegistry.luau     classify(instance) → "Weapon"|"Prop"|"None"
│
├── server/                   → ServerScriptService.Server
│   ├── init.server.luau      Bootstrap: wires all services, player lifecycle
│   ├── Remotes.luau          Creates ItemSystemRemotes + all RemoteEvents
│   ├── PhysicsAuthority.luau Collision groups + network ownership (ported)
│   ├── PlayerHoldState.luau  One-item hold rule (Weapon | Prop | None)
│   ├── AmmoLedger.luau       Authoritative ammo tracking
│   ├── DragService.luau      Physics drag rig + leash anti-cheat (ported)
│   ├── EquipService.luau     E-to-equip weapon handling
│   └── WeaponService.luau    Hitscan fire + reload + damage
│
└── client/                   → StarterPlayerScripts.Client
    ├── init.client.luau      Bootstrap: starts all controllers in order
    ├── RemotesClient.luau    Waits for ItemSystemRemotes, typed handles
    ├── InteractionController.luau  Raycast targeting, prompt, routing
    ├── DragController.luau   Mouse-hold drag steering (no rotation)
    ├── ViewmodelController.luau    First-person arms + gun, sway + bob
    └── WeaponController.luau       Predict fire, reconcile ammo, HUD
```

## Controls

| Input | Action |
|-------|--------|
| Hold **LMB** on a prop | Grab and drag |
| Release **LMB** | Drop + fling |
| **Scroll wheel** | Adjust hold distance |
| **E** on a weapon | Equip |
| **E** while weapon held | Unequip |
| **LMB click** (weapon) | Fire (hitscan) |
| **R** (weapon) | Reload |

## Item Authoring

**Props** — tag a Model/BasePart with CollectionService tag `"Interactable"`, OR set attribute `ItemType = "Prop"`.  
**Weapons** — set `ItemType = "Weapon"` and `WeaponId = "<id>"` (must match an entry in `ItemRegistry.WEAPON_DEFS`).  
**Lock a prop** — set attribute `Draggable = false`.

## Viewmodel Models

Place weapon arm/gun Models inside `ReplicatedStorage.ViewmodelAssets`.  
Each Model's name must match the `viewmodelName` field in its `WeaponDef` (e.g. `"Viewmodel_Pistol"`).  
The system runs without these; arms simply won't appear until the models exist.

## Setup (Rojo)

```bash
# Install Rojo via aftman
aftman install

# Serve to Studio
rojo serve default.project.json
```

## Design Document

See `docs/BLUEPRINT.md` (on branch `cursor/fps-item-system-design-blueprint-e7b7`) for the full v2 architectural blueprint this implementation follows.

## Consensus Build

The original two-script pickup system that this modular build was ported from lives on branch  
`cursor/master-firstperson-pickup-consensus-dd25`. All proven drag physics are preserved exactly.
