# Roblox First-Person Object Pickup System

A production-ready, modular first-person pickup and inspection system inspired by **A Dusty Trip** and **My Summer Car**. Pick up Blender-imported models, hold them in front of your camera, inspect them with mouse rotation, and drop them with physics.

## Features

- Frame-perfect camera-center raycast targeting
- `E` to pick up / drop, `R` + mouse to inspect-rotate while holding
- Modern `AlignPosition` + `AlignOrientation` constraints (no deprecated BodyMovers)
- Server-side distance and line-of-sight validation
- Client network ownership for zero-lag physics
- Held objects collide with walls but not the holding player
- Automatic Blender pivot / bounding-box correction

## Project Structure

```
src/
├── ReplicatedStorage/
│   ├── Shared/
│   │   ├── PickupConfig.luau      # Tunable constants
│   │   └── Remotes.luau           # RemoteEvent registry
│   ├── PickupSystem/
│   │   └── PhysicsUtility.luau    # Reusable physics helpers
│   └── Remotes/                   # RemoteEvent instances (Rojo)
├── ServerScriptService/
│   ├── init.server.luau
│   └── PickupSystem/
│       └── PickupServer.luau      # Server authority + validation
└── StarterPlayer/StarterPlayerScripts/
    ├── init.client.luau
    └── PickupSystem/
        └── PickupClient.luau      # Client raycast + input
```

## Setup

### 1. Sync with Rojo

```bash
rojo serve
```

Open Roblox Studio, connect the Rojo plugin, and sync the project.

### 2. Mark objects as interactable

Any `Model` or `MeshPart` imported from Blender can be picked up. Tag it using **either**:

**CollectionService tag:**
```lua
game:GetService("CollectionService"):AddTag(myModel, "Interactable")
```

**Or attribute (in Studio or script):**
```lua
myModel:SetAttribute("Interactable", true)
```

Apply the tag/attribute to the `Model` root (not individual mesh children).

### 3. Blender import tips

- Ensure the model has at least one `BasePart` / `MeshPart`
- Set a `PrimaryPart` on the Model for best results (auto-detected if missing)
- For badly centered pivots, the system auto-corrects using the bounding box
- Force bounding-box centering: `model:SetAttribute("UseBoundingCenter", true)`

### 4. First-person camera

This system assumes a first-person camera. The hold anchor tracks `workspace.CurrentCamera` on the client each frame. Use your existing first-person camera controller; no changes required.

## Controls

| Input | Action |
|-------|--------|
| `E` | Pick up targeted object / Drop held object |
| `R` + Mouse | Rotate held object for inspection |
| Crosshair | Aim at interactable objects (highlight appears) |

## Configuration

Edit `src/ReplicatedStorage/Shared/PickupConfig.luau`:

| Setting | Default | Description |
|---------|---------|-------------|
| `MAX_PICKUP_DISTANCE` | 12 | Max raycast pickup range (studs) |
| `HOLD_DISTANCE` | 4 | Distance in front of camera while held |
| `ROTATION_SENSITIVITY` | 0.004 | Mouse sensitivity while inspecting |
| `ALIGN_RESPONSIVENESS` | 200 | Constraint stiffness (higher = snappier) |

## Network Architecture

```
Client (RenderStepped)                Server
─────────────────────                ──────
Raycast → find target
Press E → PickupRequest ──────────► Validate distance + LOS
                                     Create constraints
                                     Set network ownership
◄────────────── PickupResult         Fire success/fail
Move HoldTarget (client-owned)
R + mouse → rotate offset
Press E → DropRequest ─────────────► Destroy constraints
                                     Restore collisions
```

Hold-target movement and inspection rotation run entirely on the client. Only pickup/drop use remotes, keeping network traffic minimal.

## Collision Groups

| Group | Collides with |
|-------|---------------|
| `PickupPlayer` | Everything except `PickupHeld` |
| `PickupHeld` | World geometry, other held objects |
| `Default` | Everything except `PickupHeld` ↔ `PickupPlayer` |

## Requirements

- Roblox Studio
- [Rojo](https://rojo.space/) 7.x for file sync
