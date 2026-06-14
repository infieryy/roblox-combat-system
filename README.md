# First-Person Object Pickup & Inspection System

A complete, modular, production-ready **first-person grab / hold / rotate / drop**
system for Roblox — the same feel as picking things up in *A Dusty Trip* or
*My Summer Car*. Built for **custom Models / MeshParts imported from Blender**.

It uses **only modern Luau and modern physics constraints** (`AlignPosition` +
`AlignOrientation`). There is **no** `BodyPosition`, `BodyGyro`, or any other
deprecated `BodyMover`. Objects are held smoothly and never fling the player.

---

## Features

- **Frame-perfect first-person raycast** from the centre of the camera
  (`workspace:Raycast`) to find what you're looking at.
- **Tag- or attribute-driven** interactables (`CollectionService` tag
  `"Interactable"` *or* a boolean attribute `Interactable`).
- **Press `E`** to pick up / drop. **Hold `R` + move the mouse** to rotate and
  inspect the object in front of your face (the view freezes while inspecting).
- **Server-authoritative & exploit-resistant**: the server independently
  re-validates that the target is interactable, in range, and not already held.
- **Zero-lag holding**: network ownership of the held object is transferred to
  the holder, and the owning client steers the constraint goals locally.
- **No self-collision glitching**: held objects are placed in a collision group
  that does not collide with characters, but still collides with walls/floors.
- **Blender-friendly**: objects are dragged by their *visual bounding-box
  centre*, so meshes with off-centre/custom origins still hover correctly.

---

## Project structure (Rojo)

```
default.project.json          -- Rojo mapping
src/
├── shared/    -> ReplicatedStorage/Pickup
│   ├── PickupConfig.luau      -- all tuning in one place
│   ├── Net.luau               -- RemoteEvent factory (shared)
│   └── PhysicsUtil.luau       -- reusable physics utility module
├── server/    -> ServerScriptService/Pickup
│   ├── PickupServer.server.luau   -- Script: boots the service
│   └── PickupService.luau         -- ModuleScript: authoritative logic
└── client/    -> StarterPlayer/StarterPlayerScripts/Pickup
    └── PickupController.client.luau -- LocalScript: first-person controller
```

The three core pieces requested:

| Piece | File | Class |
| --- | --- | --- |
| **Client controller** | `src/client/PickupController.client.luau` | `LocalScript` |
| **Server controller** | `src/server/PickupServer.server.luau` + `PickupService.luau` | `Script` + `ModuleScript` |
| **Physics utility module** | `src/shared/PhysicsUtil.luau` | `ModuleScript` |

---

## Installation

### With Rojo (recommended)

1. Install [Rojo](https://rojo.space/) (`aftman add rojo-rbx/rojo` or the Studio plugin).
2. From the repo root:
   ```bash
   rojo serve
   ```
3. In Roblox Studio, connect via the Rojo plugin. The tree syncs into place.

### Manual placement (no Rojo)

Recreate the structure by hand:

- `ReplicatedStorage` → Folder **`Pickup`** containing `PickupConfig`,
  `Net`, `PhysicsUtil` (all `ModuleScript`s).
- `ServerScriptService` → Folder **`Pickup`** containing `PickupServer`
  (`Script`) and `PickupService` (`ModuleScript`).
- `StarterPlayer/StarterPlayerScripts` → Folder **`Pickup`** containing
  `PickupController` (`LocalScript`).

---

## Making an object pickup-able

Pick **either** method on the Model **or** the MeshPart you want to grab:

- **Tag** it `Interactable` (Studio: *View → Tags*, or the Tag Editor plugin), or
- Add a **boolean attribute** named `Interactable` set to `true`.

That's it. The system automatically:

- resolves the whole `Model` even if your raycast hits a child part,
- picks a sensible primary part (your `PrimaryPart`, else the largest part),
- welds loose parts into one rigid assembly for the duration of the hold,
- drags by the geometric centre so off-centre Blender pivots still look right.

> Tip: leave your imported objects **unanchored** (or they will be temporarily
> unanchored on pickup and re-anchored on drop automatically).

---

## Controls

| Input | Action |
| --- | --- |
| Look at a tagged object | Highlights it and shows `[E] Pick Up` |
| `E` | Pick up (or drop what you're holding) |
| Hold `R` + move mouse | Freeze view & rotate/inspect the held object |
| Release `R` | Resume looking; the object keeps its new rotation |
| `R1` / `L1` (gamepad) | Pickup / Rotate equivalents |

---

## How it works (architecture)

### Why the client steers the constraints

The server has **no knowledge of your camera's pitch** (in first person the head
does not pitch with the camera). To get the *zero-lag* feel the brief explicitly
asks for, the design is:

1. **Server** validates the request, transfers **network ownership** to the
   holder, and **creates + fully configures** the `AlignPosition` /
   `AlignOrientation` rig (mode, forces, responsiveness, the centre attachment).
2. **The owning client** then writes only the per-frame *goal*
   (`AlignPosition.Position` and `AlignOrientation.CFrame`) based on its live
   camera. Because the client owns the assembly, this simulates locally with no
   round-trip, and the resulting `CFrame` replicates outward to the server and
   every other player for free.

This is strictly better than streaming the camera CFrame to the server every
frame (which would add a network round-trip of lag and far more bandwidth).

### Anti-exploit boundary

The trust boundary is the **pickup moment**. On `RequestPickup` the server
independently checks: the target is a `workspace` descendant, it is genuinely
tagged/attributed `Interactable`, its centre is within
`MaxPickupDistance + ServerDistanceTolerance` of the player's head, it is under
the optional mass limit, and it isn't already held. Only then is ownership
granted. (After ownership transfer the client is physically authoritative — this
is inherent to Roblox network ownership — so continuous re-validation is moot.)

### Collision handling

Two collision groups are created at runtime:

- `PickupCharacters` — every character part is placed here.
- `PickupHeldObjects` — held objects are moved here for the hold's duration.

These two groups are set **non-collidable**, so a held object never shoves a
character around (no flinging). The held group still collides with the
`Default` world, so objects bump into walls and floors normally. Original
collision groups are restored exactly on drop.

> Note: collision groups are global, so this disables held-vs-*all*-characters
> rather than held-vs-*only-the-holder*. That is the standard Roblox approach and
> is usually desirable (a held plank shouldn't knock over bystanders either).

### Blender / custom center-of-mass handling

`PhysicsUtil.getBoundingBox` uses `Model:GetBoundingBox()` (computed from real
geometry, not the pivot), and the hold attachment is placed at that geometric
centre converted into the primary part's object space. So even if Blender baked
a weird origin into your mesh, the object still hovers centred in front of you
and rotates about its visual middle.

---

## Configuration

All tuning lives in [`src/shared/PickupConfig.luau`](src/shared/PickupConfig.luau).
Common knobs:

| Setting | Meaning |
| --- | --- |
| `MaxPickupDistance` | How far you can reach (studs). |
| `HoldDistance` | How far in front of the camera the object floats. |
| `PositionResponsiveness` / `OrientationResponsiveness` | Snappy vs floaty. |
| `MaxForce` / `MaxTorque` | Constraint strength (finite — never `math.huge`). |
| `RotateSensitivity` | Inspection rotation speed (radians/pixel). |
| `MaxHoldMass` | Optional weight limit (`0` disables it). |
| `PickupKey` / `RotateKey` | Rebind the controls. |
| `ForceFirstPerson` | Lock the player into first person on join. |

---

## License

MIT — use it in anything.
