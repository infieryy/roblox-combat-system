# First-Person Pickup + Inspection System (Roblox / Luau)

Production-ready first-person object interaction system inspired by games like **A Dusty Trip** and **My Summer Car**.

## Included Modules

- `src/StarterPlayer/StarterPlayerScripts/Controllers/ObjectPickupClient.client.lua`
  - Frame-perfect center-screen raycast via `workspace:Raycast`
  - Detects `Interactable` collection tag or `Interactable` attribute
  - `E` to pickup/drop
  - Hold `R` + mouse move to rotate inspected object
- `src/ServerScriptService/Controllers/ObjectPickupServer.server.lua`
  - Server-authoritative validation of pickup ray and distance
  - Ownership transfer to holder for low-latency physics
  - Secure hold updates with camera plausibility checks
  - Automatic cleanup on drop/respawn/leave
- `src/ServerScriptService/Modules/PickupPhysicsUtil.lua`
  - Reusable physics utility API
  - Modern constraint-based hold rig using `AlignPosition` + `AlignOrientation`
  - `NoCollisionConstraint` shielding between held object and holder character only
  - Blender-friendly center-of-mass handling via model bounding-box center

## Interactable Setup

Mark pickup objects by either:

- Collection tag: `Interactable`
- OR attribute: `Interactable = true`

Supported object roots:

- `Model` (recommended for multi-part props imported from Blender)
- `BasePart` / `MeshPart`

## Controls

- **E**: Pick up / drop
- **R (hold)**: Rotate while moving mouse

## Notes

- No deprecated body movers are used.
- Uses only modern constraints and server-side validation.
- Held object collisions remain active with world geometry while ignoring only holder character parts.
