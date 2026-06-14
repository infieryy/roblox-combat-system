# First-Person Object Pickup & Inspection System

A complete, modular, production-ready Roblox (Luau) system for picking up,
holding, rotating and dropping physics objects in first person — in the style of
**A Dusty Trip** / **My Summer Car**.

It works with *any* unanchored `Model` or `MeshPart` (including custom meshes
imported from Blender) and is built entirely on **modern constraints**
(`AlignPosition` + `AlignOrientation`). No deprecated `BodyPosition` / `BodyGyro`
objects are used anywhere.

---

## Features

- **Frame-perfect first-person raycast** from the centre of the screen using
  `workspace:Raycast`.
- **Tag / attribute driven** — flag any instance with the `Interactable`
  `CollectionService` tag *or* an `Interactable = true` attribute.
- **`E` to pick up / drop**, **hold `R` + move the mouse to rotate** the held
  object in front of your face.
- **Smooth, fling-free holding** via `AlignPosition` + `AlignOrientation`.
- **Network ownership** is transferred to the holding player, so the physics are
  simulated locally and feel completely lag-free (zero per-frame remote traffic
  for movement *or* rotation).
- **Server-authoritative validation** of the pickup distance (anti-exploit),
  plus a continuous "leash" that force-drops anything dragged too far.
- **Collision filtering** so the held object never collides with characters (no
  self-flinging / shoving) while still colliding with the world (walls, floors).
- **Blender-friendly** — handles models with no `PrimaryPart` and off-centre
  pivots by carrying the object from its true **assembly centre of mass**.
- A **custom scriptable first-person camera** that hides the local character and
  hands the mouse to the inspector while you rotate an object.

---

## Project structure

This is a [Rojo](https://rojo.space) project. Source lives in `src/` and is
mapped into the DataModel by `default.project.json`:

```
src/
├── shared/        ->  ReplicatedStorage/PickupSystem   (shared modules)
│   ├── Config.luau          -- every tunable value, one source of truth
│   ├── Remotes.luau         -- creates / waits for the RemoteEvents
│   ├── Interactable.luau    -- shared "is this pickup-able?" logic
│   └── PhysicsUtil.luau     -- *** the reusable physics utility module ***
│
├── server/        ->  ServerScriptService/PickupSystem
│   ├── Main.server.luau     -- Script: thin entry point
│   └── PickupService.luau   -- ModuleScript: all authoritative logic
│
└── client/        ->  StarterPlayer/StarterPlayerScripts/PickupSystem
    ├── PickupController.client.luau  -- LocalScript: raycast, input, HUD, hold
    └── CameraController.luau          -- ModuleScript: custom FP camera
```

| Requirement                       | Where it lives                                  |
| --------------------------------- | ----------------------------------------------- |
| Client controller (LocalScript)   | `src/client/PickupController.client.luau`        |
| Server controller (Script)        | `src/server/Main.server.luau`                    |
| Server logic (ModuleScript)       | `src/server/PickupService.luau`                  |
| Reusable Physics Utility Module   | `src/shared/PhysicsUtil.luau`                    |

---

## Quick start

1. **Install tooling** (via [Aftman](https://github.com/LPGhatguy/aftman)):

   ```sh
   aftman install
   ```

2. **Sync into Studio** with the Rojo plugin:

   ```sh
   rojo serve
   ```

   …or build a place file:

   ```sh
   rojo build -o Pickup.rbxlx
   ```

3. **Make something pickup-able.** Drop any **unanchored** `Model` or `MeshPart`
   into the Workspace and either:
   - add the `Interactable` tag (Studio → *View* → *Tag Editor*), **or**
   - add a boolean attribute named `Interactable` set to `true`.

4. **Play.** Look at the object (a green crosshair + prompt appears), press **E**
   to pick it up, hold **R** and move the mouse to inspect/rotate it, and press
   **E** again to drop it.

> The tag and attribute names, ranges, forces and sensitivities are all
> configurable in `src/shared/Config.luau`.

---

## Controls

| Input            | Action                                   |
| ---------------- | ---------------------------------------- |
| Mouse            | Look around (first person)               |
| **E**            | Pick up the targeted object / drop it    |
| **Hold R** + Mouse | Rotate (inspect) the held object       |

---

## How it works

### 1. Detection & request (client)
Every render frame `PickupController` casts a ray from the camera's position
along its look vector (length `Config.MaxPickupDistance`), ignoring the local
character. The hit is resolved up its ancestry to the first instance carrying the
`Interactable` tag/attribute (`Interactable.resolve`). Pressing **E** fires the
`PickupRequest` remote with that instance.

### 2. Validation & grant (server)
`PickupService` never trusts the client's pick. It independently:
- re-resolves the interactable from the sent instance,
- confirms it isn't already held and isn't anchored,
- re-checks the distance against the **server's own** part/character positions
  (`MaxPickupDistance + ServerDistanceTolerance`),
- checks an optional mass cap,
- confirms `CanSetNetworkOwnership`.

Only then does it commit: it transfers **network ownership** to the player, builds
the constraint rig, moves the object into the held collision group, and replies
with `PickupGranted`.

### 3. Holding (client owns the physics)
Because the client is now the network owner, it drives the goals locally with
**zero network traffic**:
- `AlignPosition.Position` = `cameraPos + lookVector * holdDistance`
- `AlignOrientation.CFrame` = `cameraRotation * inspectRotation`

`holdDistance` scales to the object's bounding box so large objects float further
away. The resulting motion replicates back to the server (and other clients)
automatically through ownership.

### 4. Rotation (inspect)
While **R** is held, the camera freezes and the per-frame mouse delta is routed
to the inspector, which accumulates `inspectRotation` around the camera's up/right
axes. Again, this is purely local — no per-frame remotes.

### 5. Blender mesh handling
`PhysicsUtil` resolves a `PrimaryPart` (or the largest part if none is set),
computes the **assembly centre of mass**, and anchors the hold attachment exactly
there with `ApplyAtCenterOfMass = true`. This is what keeps off-pivot Blender
meshes from tumbling — they are carried from their true balance point. Hold
distance is derived from `Model:GetBoundingBox()` so it respects the real visual
extents rather than a mis-placed pivot.

### 6. Anti-exploit leash & cleanup
A server `Heartbeat` loop (throttled by `Config.LeashCheckInterval`) force-drops
the object if it ever leaves `MaxHoldDistance`, if it is destroyed, or if the
player dies. Drops also fire on respawn and disconnect. Dropping tears down the
rig, restores the original collision groups, clears the held attribute and returns
network ownership to the engine (`SetNetworkOwnershipAuto`).

---

## Configuration

All tuning lives in [`src/shared/Config.luau`](src/shared/Config.luau). Highlights:

| Key                       | Meaning                                                       |
| ------------------------- | ------------------------------------------------------------ |
| `Tag` / `Attribute`       | How an object is flagged as interactable                     |
| `MaxPickupDistance`       | Client raycast / pickup range (studs)                        |
| `MaxHoldDistance`         | Server leash radius before a force-drop                      |
| `HoldDistance*`           | How far in front of the camera the object floats             |
| `ForceMultiplier`         | `MaxForce = mass * gravity * ForceMultiplier`                |
| `TorqueMultiplier`        | `MaxTorque = max(mass, 1) * TorqueMultiplier`                |
| `MouseSensitivity`        | First-person look sensitivity                                |
| `RotateSensitivity`       | Object inspection rotation sensitivity                       |
| `*CollisionGroup`         | Names of the runtime-created collision groups                |

---

## Design notes & trade-offs

- **Collision groups vs. NoCollisionConstraint.** Held objects are placed in a
  `HeldObjects` collision group that is set non-collidable against the
  `Characters` group. This is the performant, replication-light approach and
  fully prevents the holder from being flung by their own object. The trade-off
  is that held objects also pass through *other* characters; if you need a held
  object to collide with other players, swap to per-pair `NoCollisionConstraint`s
  between the held parts and only the holder's character parts.
- **Network ownership.** Handing ownership to the client is what makes holding
  feel zero-lag, and it is the same technique these reference games use. The
  server validates the *initial* pickup and runs the leash loop to bound abuse;
  full server-authoritative physics would reintroduce latency.
- **Custom camera.** The scriptable first-person camera hides the local character
  (`LocalTransparencyModifier`, client-only) for a clean view. Remove
  `bindCharacter()` in `CameraController` if you want the body to stay visible.

---

## Tooling used for verification

The Luau in this repo was checked with:

- `rojo build` / `rojo sourcemap` (project + DataModel layout validity)
- `luau-lsp analyze` against the Roblox API type definitions + the generated
  sourcemap (zero type errors / warnings under `--!strict`)
