# roblox-combat-system

Server-authoritative Roblox item interaction stack with:

- physics drag props (mouse-hold + release fling),
- weapon equip on `E`,
- first-person viewmodel rendering,
- hitscan shooting with server validation.

## Project layout

```text
src/
  shared/
    Config.luau
    GeometryUtil.luau
    ItemRegistry.luau
    Types.luau
  server/
    init.server.luau
    Remotes.luau
    PhysicsAuthority.luau
    PlayerHoldState.luau
    AmmoLedger.luau
    DragService.luau
    EquipService.luau
    WeaponService.luau
  client/
    init.client.luau
    RemotesClient.luau
    InteractionController.luau
    DragController.luau
    ViewmodelController.luau
    WeaponController.luau
```

## Item authoring

### Props (draggable)

Any `Model`/`BasePart` can be treated as a prop via either:

- `ItemType = "Prop"` attribute, or
- legacy `Interactable` CollectionService tag / boolean `Interactable = true`.

Optional prop attributes:

- `Draggable = false` to lock dragging.

### Weapons

Set on a `Model` or `BasePart`:

- `ItemType = "Weapon"`
- `WeaponId = "pistol_9mm"` (or another ID present in `src/shared/ItemRegistry.luau`)

## Controls

- **Mouse1 (hold)**: drag prop while looking at it
- **Mouse1 (release)**: drop/fling dragged prop
- **Mouse wheel**: move dragged prop closer/farther
- **E**: equip looked-at weapon (or unequip current weapon)
- **Mouse1 (weapon equipped)**: fire
- **R**: reload

## Run with Rojo

`default.project.json` maps:

- `src/shared` -> `ReplicatedStorage.Shared`
- `src/server` -> `ServerScriptService.Server`
- `src/client` -> `StarterPlayer.StarterPlayerScripts.Client`
