# roblox-combat-system

Roblox combat architecture with drag-to-equip, server-authoritative weapon flow,
and camera-attached viewmodel rendering.

## Layout

- `default.project.json`: Rojo mapping for Roblox services.
- `src/ReplicatedStorage/Combat/WeaponDefinitions.lua`: shared weapon + viewmodel config.
- `src/ReplicatedStorage/Combat/CombatRemotes.lua`: remote names and resolver utility.
- `src/ServerScriptService/Combat/CombatService.server.lua`: equip/fire/reload/drag authority.
- `src/StarterPlayer/StarterPlayerScripts/Combat/DragController.lua`: drag lifecycle on client.
- `src/StarterPlayer/StarterPlayerScripts/Combat/ViewmodelController.lua`: viewmodel placement + sway.
- `src/StarterPlayer/StarterPlayerScripts/Combat/WeaponController.lua`: client weapon orchestration.
- `src/StarterPlayer/StarterPlayerScripts/Combat/CombatClient.client.lua`: bootstrap.

## Drag Integration Contract

Any draggable world item can participate when it has:

- Attribute: `WeaponId` (string that matches `WeaponDefinitions.ById`).
- Optional tag: `DraggableWeapon` for explicit drag targeting.
- Optional attribute on drop targets: `WeaponEquipZone = true`.

Drag behavior:

1. Begin drag on left mouse down over draggable target.
2. Update drag position every frame (and network updates at 20Hz).
3. End drag on mouse release.
4. If release target is character/equip zone, client requests equip and server validates.

## Controls

- `LMB`: fire equipped weapon.
- `R`: reload.
- `X`: unequip.
