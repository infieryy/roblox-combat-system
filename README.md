# roblox-combat-system

Unified first-person Roblox item stack with:

- authoritative **prop dragging** (server-created hold rig, client-steered),
- **weapon equipping** and server hitscan,
- **viewmodel rendering** with sway/bob/kickback.

## Layout

```
default.project.json
src/
├── shared/   -> ReplicatedStorage/Shared
├── server/   -> ServerScriptService/Server
└── client/   -> StarterPlayerScripts/Client
```

## Controls

- Look at **Weapon** + `E` -> equip.
- Look at **Prop** + hold `LMB` -> drag.
- Release `LMB` -> drop.
- With weapon equipped: `LMB` fire, `R` reload.

## Item attributes

- `ItemType`: `"Weapon"` or `"Prop"` (required).
- `WeaponId`: weapon registry key (required for `ItemType="Weapon"`).
- `Draggable`: optional bool for props (defaults true).
- `Interactable`: optional bool/tag fallback for props.

## Notes

- RemoteEvents are created at runtime in `ReplicatedStorage.ItemSystemRemotes`.
- Drag path keeps network ownership + server leash validation.
- Equip/fire/reload is server-authoritative; client prediction is reconciled by `FireResult`/`EquipResult`.
