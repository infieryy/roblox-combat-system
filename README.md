# roblox-combat-system

First-person **item & combat system** for Roblox (Luau + Rojo), built from the v2 bridged blueprint in `docs/BLUEPRINT.md`.

## What this repo contains

| Layer | Path (repo) | Roblox location | Role |
| ----- | ----------- | --------------- | ---- |
| Shared | `src/shared/` | `ReplicatedStorage.Shared` | `Config`, `Types`, `GeometryUtil`, `ItemRegistry` |
| Server | `src/server/` | `ServerScriptService.Server` | Authoritative drag, equip, ammo, hitscan |
| Client | `src/client/` | `StarterPlayerScripts.Client` | Interaction, drag steering, viewmodel, weapon input |

### Consensus drag code (ported)

The physics drag rig from branch `cursor/master-firstperson-pickup-consensus-dd25` was ported into:

- `src/server/DragService.luau` — AlignPosition/AlignOrientation rig, leash, network ownership
- `src/client/DragController.luau` — client-side constraint steering
- `src/shared/GeometryUtil.luau` — de-duplicated Blender-safe geometry helpers

### New combat systems

- `src/client/ViewmodelController.luau` — first-person arms + gun (procedural fallback, or Studio assets in `ReplicatedStorage.Viewmodels`)
- `src/client/WeaponController.luau` — click-to-fire prediction, HUD, tracers
- `src/server/WeaponService.luau` — server hitscan validation + damage
- `src/server/EquipService.luau` — E-to-equip weapons
- `src/server/PlayerHoldState.luau` — one item at a time (weapon **or** prop)

## Controls

| Input | Action |
| ----- | ------ |
| **Hold LMB** on a prop | Grab and drag (physics) |
| **Release LMB** | Drop / fling |
| **E** on a weapon | Equip |
| **E** while holding weapon | Unequip |
| **LMB** while holding weapon | Fire (hitscan) |
| **R** while holding weapon | Reload |
| **Q** while dragging | Force drop |
| **Scroll** while dragging | Adjust hold distance |

Props use **mouse grab only** (no E). E is reserved for weapons.

## Authoring items in Studio

| Attribute | Value | Meaning |
| --------- | ----- | ------- |
| `ItemType` | `"Prop"` | Draggable physics object |
| `ItemType` | `"Weapon"` | Equippable gun |
| `WeaponId` | e.g. `pistol_9mm` | Registry key (see `ItemRegistry.luau`) |
| `Interactable` tag/attr | (legacy) | Treated as **Prop** for backward compatibility |

Optional viewmodel meshes: place models under `ReplicatedStorage.Viewmodels` named `pistol_9mm`, `rifle_ar`, etc.

## Sync with Rojo

```bash
rojo serve default.project.json
```

Then connect from Roblox Studio.

## Source branches

- **Blueprint:** `cursor/fps-item-system-design-blueprint-e7b7` → `docs/BLUEPRINT.md`
- **Consensus drag (ported from):** `cursor/master-firstperson-pickup-consensus-dd25`
