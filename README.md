# First-Person Pickup and Inspection System (Roblox Luau)

Production-ready modular system for first-person pickup / inspection gameplay similar to **A Dusty Trip** or **My Summer Car**.

## Folder Structure

Place scripts in these Roblox services (or equivalent Rojo paths):

- `ReplicatedStorage/Shared/PhysicsPickupUtil.lua`
- `ServerScriptService/PickupServerController.server.lua`
- `StarterPlayer/StarterPlayerScripts/PickupClientController.client.lua`

## Interactable Requirements

An object can be picked up if either of these is true on the object root (or an ancestor root):

1. CollectionService tag: `"Interactable"`
2. Attribute: `Interactable = true`

Supported roots:

- `BasePart` (including `MeshPart`)
- `Model` (for Blender imports with multiple parts)

## Input

- `E`: Pick up / Drop
- Hold `R` + move mouse: Rotate while held

## Networking / Security

- Client runs frame-level center-camera raycasts with `workspace:Raycast`.
- Server revalidates:
  - Interactable root/tag/attribute
  - Max pickup distance
  - Server line-of-sight raycast
  - Client-provided raycast sanity checks (origin and hit target)
- Held object network ownership is transferred to the holder for responsive physics.

## Physics Approach

- Uses **AlignPosition** + **AlignOrientation** (no deprecated Body movers).
- Uses runtime **NoCollisionConstraint** pairs between held parts and the holder's character parts.
  - Prevents self-collision jitter while preserving collisions against world geometry.
- Uses model bounding box center to place attachment forces, improving stability on Blender meshes with off-center pivots.
