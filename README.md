# roblox-combat-system

First-person item & combat system for Roblox — physics drag, weapon equip, viewmodel arms, and server-authoritative hitscan shooting.

Built from the **Master Design Blueprint v2** (`docs/BLUEPRINT.md`), bridging the proven consensus pickup/drag build with guns, viewmodels, and shooting.

## Architecture

| Layer | Path | Role |
| ----- | ---- | ---- |
| Shared | `src/shared/` | `Config`, `Types`, `GeometryUtil`, `ItemRegistry` |
| Server | `src/server/` | `DragService`, `EquipService`, `WeaponService`, `PlayerHoldState`, `AmmoLedger` |
| Client | `src/client/` | `InteractionController`, `DragController`, `ViewmodelController`, `WeaponController` |

## Controls

| Input | Action |
| ----- | ------ |
| **Left Click** (empty hands, looking at prop) | Grab and drag (release to fling) |
| **E** (looking at weapon) | Equip weapon |
| **Left Click** (weapon equipped) | Fire hitscan |
| **R** | Reload |
| **Q** (while dragging) | Drop held prop |
| **Scroll** (while dragging) | Adjust hold distance |

## Authoring items in Studio

### Props (mouse-grab)
- Set attribute `ItemType = "Prop"`, **or** use legacy tag/attribute `Interactable`
- Optional: `Draggable = false` to lock

### Weapons (E to equip)
- Set attribute `ItemType = "Weapon"`
- Set attribute `WeaponId` to a registry key (e.g. `pistol_9mm`, `rifle_ar`)
- Place a viewmodel model under `ReplicatedStorage.Viewmodels/<viewmodelName>` (procedural fallback if missing)

## Sync with Rojo

```bash
rojo serve
```

Then connect from Roblox Studio using the Rojo plugin.

## Source lineage

- **Drag physics:** ported from `cursor/master-firstperson-pickup-consensus-dd25`
- **Guns/arms/shooting:** new modules per `docs/BLUEPRINT.md`
