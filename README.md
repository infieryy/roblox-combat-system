# roblox-combat-system

A first-person **item & combat system** for Roblox (Luau, server-authoritative,
Rojo). It implements the master design in [`docs/BLUEPRINT.md`](docs/BLUEPRINT.md):
the proven physics **drag** system (ported from the consensus build) plus
**first-person arms/viewmodel, weapon equipping, and hitscan shooting** built on
top of it.

## Core behaviour

- **Props** — look at a draggable prop and **hold the mouse** to grab it (no key).
  It floats in front of you (scroll to push/pull), and **releasing flings it**
  (velocity is retained and clamped). Props are carried, not rotated.
- **Weapons** — look at a weapon and press **E** to equip it. First-person arms +
  gun appear with sway/bob. **Left-click fires** (hitscan), **R reloads**, **E
  holsters**.
- **One item at a time** — equipping a gun auto-releases a held prop and grabbing
  a prop auto-holsters a gun. The server is the single source of truth.

## Project structure (Rojo → `default.project.json`)

```
src/
├── shared/   → ReplicatedStorage.Shared
│   ├── Config.luau        -- single source of truth for every tunable value
│   ├── Types.luau         -- WeaponDef / HoldState / HoldRig
│   ├── GeometryUtil.luau  -- Blender-safe geometry (ported)
│   └── ItemRegistry.luau  -- classify Weapon/Prop/None + weapon defs
├── server/   → ServerScriptService.Server
│   ├── init.server.luau   -- entry point + lifecycle wiring
│   ├── Remotes.luau       -- builds ItemSystemRemotes (the only doors)
│   ├── PhysicsAuthority.luau -- collision groups + network ownership (ported)
│   ├── PlayerHoldState.luau  -- authoritative "what are you holding"
│   ├── AmmoLedger.luau    -- sole authoritative ammo mutator
│   ├── DragService.luau   -- ported pickup rig + leash + fixes (§14)
│   ├── EquipService.luau  -- equip/unequip + one-item swap
│   └── WeaponService.luau -- authoritative hitscan + fire-rate + LoS
└── client/   → StarterPlayer.StarterPlayerScripts.Client
    ├── init.client.luau
    ├── RemotesClient.luau
    ├── InteractionController.luau -- targeting/highlight + item routing
    ├── DragController.luau        -- mouse-grab constraint steering (ported)
    ├── ViewmodelController.luau   -- first-person arms+gun, sway/bob/kick
    └── WeaponController.luau      -- click→predict→fire, tracers, ammo HUD
```

## Authoring content

Set Studio **attributes** on a `Model` or `BasePart` in the Workspace:

| Attribute    | Value      | Effect                                              |
| ------------ | ---------- | --------------------------------------------------- |
| `ItemType`   | `"Weapon"` | Equippable with **E**. Also set `WeaponId`.         |
| `ItemType`   | `"Prop"`   | Mouse-grabbable physics prop.                       |
| `WeaponId`   | string     | Registry key, e.g. `pistol_9mm`, `rifle_556`.       |
| `Draggable`  | `false`    | Locks a prop so it cannot be grabbed.               |
| `Interactable` | `true` / tag | Legacy flag — still treated as a **Prop**.      |

Weapon definitions live in `src/shared/ItemRegistry.luau` (`pistol_9mm`,
`rifle_556` out of the box). Optional world/viewmodel assets are looked up by
name in `ReplicatedStorage.Viewmodels` (client) and `ServerStorage.WeaponModels`
/ `ReplicatedStorage.WeaponModels` (server); if absent, a procedural gun is built
so everything works with zero external assets.

## Controls

| Input              | Action                                  |
| ------------------ | --------------------------------------- |
| Hold **Mouse 1**   | Grab a prop (empty-handed) — release to drop/fling |
| Mouse wheel        | Push/pull a held prop                   |
| **E**              | Equip a targeted weapon / holster       |
| **Mouse 1**        | Fire the equipped weapon                |
| **R**              | Reload                                   |

## Tooling

Rojo project. `rojo serve` (or `rojo build -o place.rbxlx`) and sync in Studio.
All source compiles under the Luau compiler; see `docs/BLUEPRINT.md` for the full
contract, anti-cheat checklist, and testing plan.
