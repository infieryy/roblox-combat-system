# roblox-combat-system

A first-person item & combat system for Roblox (Luau + Rojo), built server-authoritative.

## Features
- **First-person viewmodel** arms + gun with smooth look-sway and walk-bob.
- **Weapons:** press **E** to equip (gun snaps into hands).
- **Props:** mouse-drag only — grab, move, and fling (physics-based, *A Dusty Trip* style). **No E for props.**
- **Hitscan** shooting with full server-side anti-cheat validation (ammo, fire-rate, line-of-sight, plausibility).
- **One item held at a time**, enforced authoritatively on the server (equipping a gun auto-drops a held prop and vice-versa).

## Architecture (server-authoritative)
The client requests and predicts; the server decides and owns truth. The proven drag physics from the
"consensus build" (`AlignPosition` + `AlignOrientation`, network-ownership transfer, collision-group
isolation, leash anti-cheat) is ported into a modular layout and the gun/arms/shooting systems are layered
on top of the same pattern: **the server builds the rig, the owning client steers the constraint goals.**

```
ReplicatedStorage.Shared    <- src/shared   (Config, Types, GeometryUtil, ItemRegistry)
ServerScriptService.Server  <- src/server   (Remotes, PhysicsAuthority, PlayerHoldState,
                                             AmmoLedger, DragService, EquipService, WeaponService)
StarterPlayerScripts.Client <- src/client   (RemotesClient, InteractionController, DragController,
                                             ViewmodelController, WeaponController)
```

## Documentation
- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)** — the master design blueprint (v2, *bridged*). Frozen
  RemoteEvent/module contracts, data schemas, end-to-end flows, refinements & bug fixes for the original
  scripts, and the anti-cheat checklist.

## Toolchain
- Roblox · Luau · [Rojo](https://rojo.space) (the Git repo is the source of truth; code only).
- Sync into Studio with `rojo serve` and the Rojo plugin, or build with `rojo build -o place.rbxlx`.

## Authoring items in Studio
Set attributes on a `Model` or `BasePart` in `Workspace`:

| Attribute | Type | Meaning |
|---|---|---|
| `ItemType` | string | `"Weapon"` or `"Prop"`. |
| `WeaponId` | string | Registry key for a weapon, e.g. `"pistol_9mm"` (see `ItemRegistry`). |
| `Interactable` | bool | Legacy flag → treated as a `Prop` (back-compat with the consensus build). |
| `Draggable` | bool | Optional; default `true`. Set `false` to lock a prop. |

A weapon also needs a `WeaponId` whose key exists in `ItemRegistry.getAllWeaponDefs()`.
