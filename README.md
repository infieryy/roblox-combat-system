# roblox-combat-system

A first-person item & combat system for Roblox (Luau + Rojo), built server-authoritative.

## Features

- **Props:** mouse-drag only — grab, move, and fling (physics-based, *A Dusty Trip* style).
- **Weapons:** press **E** to equip; left-click to fire hitscan shots.
- First-person viewmodel arms + gun with smooth sway/bob.
- One item held at a time, enforced authoritatively on the server.
- Full server-side anti-cheat validation for drag, equip, and shooting.

## Documentation

- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)** — master design blueprint (v2, bridged).

## Project layout

```
src/
├── shared/          → ReplicatedStorage.Shared
├── server/          → ServerScriptService.Server
└── client/          → StarterPlayerScripts.Client
```

## Toolchain

```bash
rojo serve
# or
rojo build -o roblox-combat-system.rbxlx
```

## Authoring items in Studio

| Attribute | Type | Meaning |
|-----------|------|---------|
| `ItemType` | string | `"Weapon"` or `"Prop"` |
| `WeaponId` | string | Registry key (weapons), e.g. `"pistol_9mm"` |
| `Interactable` | bool/tag | Legacy — treated as `Prop` |

### Controls

| Input | Action |
|-------|--------|
| Left mouse (empty-handed, on prop) | Grab and drag |
| Release mouse | Drop / fling |
| Scroll wheel | Adjust hold distance while dragging |
| **E** (on weapon) | Equip |
| Left click (weapon equipped) | Fire |
| **R** | Reload |

## Studio assets

Place viewmodel rigs under `ReplicatedStorage.Viewmodels/<viewmodelName>`. If missing, a procedural fallback viewmodel is built at runtime.
