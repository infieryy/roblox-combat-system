# First-Person Object Pickup & Inspection System

A complete, modular, production-ready first-person **pickup / hold / rotate / drop**
system for Roblox, in the style of *A Dusty Trip* and *My Summer Car*. It lets a
player walk up to any tagged `Model` or `MeshPart` (including custom Blender
imports), grab it, drag it around in front of the camera, spin it to inspect it,
and drop it again — all with smooth, exploit-resistant physics.

It is built entirely with **modern Luau** and **modern physics constraints**
(`AlignPosition` + `AlignOrientation`). There are **no deprecated objects**
(`BodyPosition`, `BodyGyro`, etc.).

---

## Features

- **Frame-perfect first-person targeting** — a `workspace:Raycast` from the
  camera center each frame, with a `Highlight` and a contextual on-screen prompt.
- **Tag *or* attribute detection** — objects opt in via the `Interactable`
  CollectionService tag **or** an `Interactable` attribute.
- **Smooth, fling-free holding** — `AlignPosition` + `AlignOrientation` in
  `OneAttachment` mode, with forces/torques scaled to each object's mass and
  bounding size so light and heavy props feel equally controlled.
- **Zero-lag feel** — network ownership of the held assembly is handed to the
  holder, and the client drives the constraint goals locally every frame.
- **Hold-to-inspect** — hold **R** and move the mouse to rotate the object in
  front of your face; scroll to push/pull it closer or further.
- **Surgical collision filtering** — `NoCollisionConstraint`s disable collisions
  between the held object and the holder's *own* character only; it still
  collides with walls, the floor and other players.
- **Blender-import friendly** — uses `Model:GetBoundingBox()` and
  `BasePart.AssemblyCenterOfMass` so off-center pivots don't cause spinning or
  inaccurate forces.
- **Server-authoritative & exploit-resistant** — the server validates reach,
  line-of-sight, mass and ownership at pickup, then continuously "leashes" held
  objects and force-drops anything moved out of bounds.
- **Minimal replication** — only two client→server intents (`pickup`, `drop`)
  and two server→client notifications. No per-frame remotes.

---

## Project structure

```
default.project.json          -- Rojo mapping

src/
├── shared/                    -> ReplicatedStorage/PickupSystem  (Folder)
│   ├── Config.lua             -- all shared tuning values
│   ├── PhysicsUtil.lua        -- reusable physics utility module
│   └── Remotes.lua            -- creates / fetches the RemoteEvents
│
├── server/                    -> ServerScriptService/PickupServer (Script)
│   ├── init.server.lua        -- bootstrap Script
│   ├── PickupService.lua      -- server controller (ModuleScript)
│   └── SampleObjects.lua      -- optional demo prop spawner (ModuleScript)
│
└── client/                    -> StarterPlayer/StarterPlayerScripts/PickupClient (LocalScript)
    ├── init.client.lua        -- bootstrap LocalScript
    └── PickupController.lua    -- client controller (ModuleScript)
```

This satisfies the requested layout: a **Client controller**, a
**Server controller**, and a reusable **Physics Utility Module**, plus a shared
`Config` so the two sides never disagree on the rules.

---

## Installation

### With [Rojo](https://rojo.space) (recommended)

1. Install Rojo (`aftman add rojo-rbx/rojo` or the VS Code extension).
2. From the repo root, run `rojo serve` and connect from Roblox Studio,
   or `rojo build -o Place.rbxlx` to produce a place file.

The `default.project.json` already maps every file to the correct service.

### Manual import

Recreate the tree shown above in Studio and paste each file into the matching
`Script` / `LocalScript` / `ModuleScript`. The folder named files (`init.*.lua`)
become the parent `Script`/`LocalScript`; the sibling `.lua` files become child
`ModuleScript`s.

---

## Usage

1. **Tag your objects.** For any prop you want to be pickable, either:
   - add the `Interactable` tag (Studio → *View* → *Tag Editor*), **or**
   - set an attribute `Interactable = true`.

   This works on a single `MeshPart`/`Part` or on a whole `Model`. For a Model,
   set a `PrimaryPart` if you can — otherwise the heaviest part is used as the
   driver and loose parts are welded into a single assembly automatically.

2. **Play.** The system enables a custom first-person camera automatically.
   - Look at a tagged object → it highlights and shows `[E] Pick up`.
   - Press **E** to pick it up; press **E** again to drop it.
   - Hold **R** and move the mouse to rotate/inspect the object.
   - Scroll the mouse wheel to push it away or pull it closer.

3. **Try it instantly (optional).** Set `Config.SpawnSampleObjects = true` to
   have the server spawn a crate, a barrel and a plank near the origin.

---

## How it works

### Detection & targeting (client)
`PickupController` runs a raycast from `camera.CFrame.Position` along its
`LookVector` every render frame, ignoring the local character. The hit instance
is resolved up its ancestry to the nearest `Interactable` (`PhysicsUtil.resolveInteractable`),
which is highlighted.

### Pickup request & validation (server)
Pressing **E** fires `RequestPickup(targetInstance)`. `PickupService` re-validates
everything authoritatively:

- the target really is interactable,
- it isn't already held,
- the driver part exists and isn't anchored,
- the assembly mass is under `Config.MaxHoldMass`,
- the target is within `MaxPickupDistance` (× a small latency tolerance) of the
  player's head,
- a head→target raycast confirms **line of sight** (you can't grab through walls).

### The hold rig (server)
`PhysicsUtil.createHoldRig` builds, on the driver part:

- an `Attachment` placed exactly at the assembly's **center of mass** with the
  driver's orientation,
- an `AlignPosition` (`OneAttachment`, `ApplyAtCenterOfMass = true`) whose
  `MaxForce = mass * gravity * multiplier` — consistent acceleration for any mass,
- an `AlignOrientation` (`OneAttachment`) whose
  `MaxTorque ≈ mass * boundingRadius² * multiplier` — consistent spin for any size.

Both goals are initialised to the object's current pose so it doesn't snap when
the rig switches on. `MaxVelocity` / `MaxAngularVelocity` caps + tuned
`Responsiveness` keep it smooth and prevent flinging.

### Ownership & collisions (server)
The driver's `SetNetworkOwner` is set to the holder so physics simulate on their
machine (zero perceived lag). `PhysicsUtil.disableCharacterCollisions` creates a
`NoCollisionConstraint` between every held part and every character part, so the
object glides past its carrier but still hits the world.

### Driving the object (client)
Because the client owns the assembly, `PickupController` simply writes
`alignPosition.Position` and `alignOrientation.CFrame` every frame from the
camera (plus the accumulated inspect rotation while **R** is held). No remotes
are sent during a hold.

### Anti-exploit leash (server)
A `Heartbeat` loop measures each held object's distance from its holder. If a
client drifts the object past the allowed radius for longer than
`Config.LeashGracePeriod`, the server force-drops it. Drops also happen on death,
disconnect, or if the object is destroyed.

---

## Configuration

All tuning lives in `src/shared/Config.lua`. Highlights:

| Setting | Meaning |
| --- | --- |
| `InteractTag` / `InteractAttribute` | how objects opt in |
| `MaxPickupDistance` | reach of the pickup raycast / server gate |
| `HoldDistance`, `Min/MaxHoldDistance` | how far in front the object floats |
| `MaxHoldMass` | reject absurdly heavy assemblies |
| `LeashGracePeriod` | grace before force-dropping an out-of-bounds object |
| `Position*` / `Orientation*` | constraint force/torque/responsiveness tuning |
| `PickupKey`, `RotateKey` | default `E` and `R` |
| `LookSensitivity`, `RotateSensitivity`, `PitchLimit` | camera & inspect feel |
| `HideCharacterInFirstPerson` | hide the local body so it never blocks the view |
| `SpawnSampleObjects` | spawn demo props for quick testing |

---

## Requirements

- Roblox Studio (any modern version — uses current constraint and attribute APIs).
- Optional: [Rojo](https://rojo.space) for the file-based workflow.
