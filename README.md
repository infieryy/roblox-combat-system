# roblox-combat-system

A first-person item & combat system for Roblox (Luau + Rojo), built server-authoritative.

## Features (planned)
- First-person viewmodel arms + gun with smooth sway/bob.
- **Weapons:** press **E** to equip (snaps into hands).
- **Props:** mouse-drag only — grab, move, and fling (physics-based, *A Dusty Trip* style).
- **Hitscan** shooting with full server-side anti-cheat validation.
- One item held at a time, enforced authoritatively on the server.

## Documentation
- **[docs/BLUEPRINT.md](docs/BLUEPRINT.md)** — the master design blueprint (v2, *bridged*). Read this in full before writing any code. It bridges the existing first-person pickup/inspection "consensus build" with the gun/arms/shooting vision: a migration map (consensus code → modules), frozen RemoteEvent/module contracts, data schemas, end-to-end flows, refinements & bug fixes for the existing scripts, the anti-cheat checklist, and a 10-agent parallel build plan.

## Current code
The working pickup/inspection system lives on the branch `cursor/master-firstperson-pickup-consensus-dd25` (two self-contained scripts). The blueprint describes how to port that proven physics into a modular layout and layer weapons, viewmodel arms, and hitscan shooting on top.

## Toolchain
- Roblox · Luau · Rojo (the Git repo is the source of truth; code only).
