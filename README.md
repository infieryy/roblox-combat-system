# roblox-combat-system

First-person **item & combat system** for Roblox — physics drag, weapon equip, viewmodel arms, and server-authoritative hitscan shooting.

Built from the **consensus pickup build** (`cursor/master-firstperson-pickup-consensus-dd25`) bridged with the **v2 blueprint** (`docs/BLUEPRINT.md`).

## Architecture

| Layer | Path (Rojo) | Role |
| ----- | ----------- | ---- |
| Shared | `src/shared` → `ReplicatedStorage.Shared` | `Config`, `Types`, `GeometryUtil`, `ItemRegistry` |
| Server | `src/server` → `ServerScriptService.Server` | `DragService`, `EquipService`, `WeaponService`, `PlayerHoldState`, `AmmoLedger` |
| Client | `src/client` → `StarterPlayerScripts.Client` | `InteractionController`, `DragController`, `ViewmodelController`, `WeaponController` |

## Controls

| Input | Action |
| ----- | ------ |
| **Hold Left Click** (empty hands, looking at prop) | Grab & drag physics prop |
| **Release Left Click** | Drop / fling prop |
| **E** (looking at weapon) | Equip gun |
| **Left Click** (weapon equipped) | Fire (hitscan) |
| **R** (weapon equipped) | Reload |
| **Q** (while dragging) | Drop prop |
| **Scroll** (while dragging) | Adjust hold distance |

## Authoring items in Studio

### Props (mouse drag)
- Set attribute `ItemType = "Prop"`, **or** use legacy `Interactable` tag / attribute.
- Must be unanchored `Model` or `BasePart`.
- Optional `Draggable = false` to lock.

### Weapons (E to equip)
- Set `ItemType = "Weapon"` and `WeaponId` (e.g. `pistol_9mm`, `rifle_556`).
- Place a weapon model in Workspace.

### Viewmodel assets (optional)
Place custom viewmodels under `ReplicatedStorage.Assets.Viewmodels`:
- `PistolViewmodel` for `pistol_9mm`
- `RifleViewmodel` for `rifle_556`

If missing, procedural fallback arms + gun are generated at runtime.

## Rojo

```bash
rojo serve
```

Connect from the Roblox Studio Rojo plugin.

## Source branches

- **Consensus drag physics:** `cursor/master-firstperson-pickup-consensus-dd25`
- **Design blueprint:** `cursor/fps-item-system-design-blueprint-e7b7`
