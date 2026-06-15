# roblox-combat-system

A first-person item & combat system for Roblox (Luau + Rojo), built server-authoritative.

## Features (planned)
- First-person viewmodel arms + gun with smooth sway/bob.
- **Weapons:** press **E** to equip (snaps into hands).
- **Props:** mouse-drag only — grab, move, and fling (physics-based, *A Dusty Trip* style).
- **Hitscan** shooting with full server-side anti-cheat validation.
- One item held at a time, enforced authoritatively on the server.

## Documentation
- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)** — the master design blueprint. Read this in full before writing any code. It defines the architecture, the frozen RemoteEvent/module contracts, data schemas, end-to-end flows, the anti-cheat checklist, and a 10-agent parallel build plan.

## Toolchain
- Roblox · Luau · Rojo (the Git repo is the source of truth; code only).
