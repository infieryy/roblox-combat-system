# First-Person Object Pickup + Inspection System (Roblox)

Production-ready modular system for first-person pickup/drag/inspect gameplay inspired by titles like **A Dusty Trip** and **My Summer Car**.

## Included Modules

- `src/StarterPlayer/StarterPlayerScripts/ObjectPickupClient.client.lua`
  - Frame-perfect center-screen raycast (`workspace:Raycast`) every render frame
  - Sends secure pickup/drop/hold/rotate requests via RemoteEvent
  - `E` to pickup/drop, hold `R` + mouse move to rotate held object

- `src/ServerScriptService/ObjectPickupServer.server.lua`
  - Authoritative pickup validation (distance + line of sight)
  - Assigns network ownership to holder for low-latency physics
  - Drives hold behavior with `AlignPosition` + `AlignOrientation`
  - Prevents held-object collision with holder's character only
  - Cleans up constraints safely on drop/reset/leave

- `src/ReplicatedStorage/Shared/PhysicsUtil.lua`
  - Reusable physics utility module for hold rig creation/destruction
  - Handles `Model`/`MeshPart` assemblies, attachment centering, temporary welds
  - Uses model `Pivot` + `BoundingBox` center to compensate Blender pivot/COM issues

## Interactable Setup

Mark pickup targets using either:

1. CollectionService tag: `Interactable`
2. Attribute on the part/model: `Interactable = true`

The interactable root can be either a `Model` or a `BasePart`.

## Replicated Storage Remote

Server auto-creates:

- `ReplicatedStorage/Remotes/ObjectPickupRemote` (`RemoteEvent`)

No manual remote setup needed.

## Controls

- `E`: pickup / drop
- Hold `R` + mouse movement: rotate held object

## Notes

- Uses modern constraints only (`AlignPosition`, `AlignOrientation`)
- Does **not** use deprecated body movers
- Designed to preserve wall collisions while suppressing self-collision against the holder
