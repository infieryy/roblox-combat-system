# First-Person Object Pickup & Inspection System

A complete, modular, production-ready first-person **pick up / hold / rotate / drop**
system for Roblox, in the spirit of *A Dusty Trip* and *My Summer Car*. It works
with **any** custom `Model` or `MeshPart` imported from Blender.

Built with strictly modern Luau and **modern physics constraints only**
(`AlignPosition`, `AlignOrientation`, `WeldConstraint`, `NoCollisionConstraint`) —
no deprecated `BodyPosition` / `BodyGyro`.

---

## Features

- **Frame-perfect raycast** from the centre of the first-person camera
  (`workspace:Raycast`) every render frame.
- **Tag _or_ attribute** detection — flag objects with the `Interactable`
  CollectionService tag or an `Interactable` boolean attribute.
- **Press `E`** to pick up / drop; **hold `R` + move the mouse** to rotate and
  inspect the object in front of your face; **`Q`** to drop.
- **Server-authoritative & exploit-resistant** — the server re-validates reach
  distance and clamps the held position to a safe radius around the player.
- **Zero-lag holding** — network ownership is transferred to the holder and the
  constraints are predicted locally on the owning client, while the goal is
  streamed to the server (over an `UnreliableRemoteEvent`) for replication to
  everyone else.
- **No self-collision flinging** — `NoCollisionConstraint`s disable collision
  between the held object and the holder's _own_ character only; the object
  still collides with walls, floors and other players.
- **Blender-friendly** — positions are derived from the engine bounding box
  (`Model:GetBoundingBox()`), not the often off-centre imported pivot, and the
  drag force is applied at the real centre of mass (`ApplyAtCenterOfMass`) so
  lopsided meshes don't spin uncontrollably.
- **Mass-aware tuning** — forces/torques scale with assembly mass and velocity
  is capped, so light and heavy objects both feel responsive and nothing flings.

---

## Project structure

```
src/
├─ ReplicatedStorage/
│  └─ PickupSystem/                 (Folder, shared)
│     ├─ Config.luau                (ModuleScript) all tunables
│     ├─ PhysicsUtil.luau           (ModuleScript) reusable physics helpers
│     └─ Remotes.luau               (ModuleScript) remote event plumbing
├─ ServerScriptService/
│  └─ PickupServer.server.luau      (Script) authoritative controller
└─ StarterPlayer/
   └─ StarterPlayerScripts/
      └─ PickupClient.client.luau   (LocalScript) first-person controller
```

| Module | Role |
| --- | --- |
| `Config` | Every tunable value (keys, distances, force/torque scaling, network rate). |
| `PhysicsUtil` | Stateless helpers: resolve handle, bounding box, mass, weld, ownership, build the drag rig, self-collision filtering. |
| `Remotes` | Creates (server) / waits for (client) the `RemoteEvent`s and the `UnreliableRemoteEvent`. |
| `PickupServer` | Validates requests, transfers ownership, builds/drives the rig, watchdog + lifecycle cleanup. |
| `PickupClient` | Raycast targeting, UI, input, local goal computation + prediction, inspect/rotate. |

---

## Installation

### With [Rojo](https://rojo.space) (recommended)

```bash
rojo serve   # then connect from the Roblox Studio plugin
# or build a place/model file:
rojo build -o pickup-system.rbxlx
```

The included `default.project.json` maps each source file to the correct service.

### Manual

Recreate the tree above in Studio and paste each file into a matching
`ModuleScript` / `Script` / `LocalScript`.

---

## Usage

1. Install the system (above).
2. Make an object grabbable in **either** of these ways:
   - Add the **`Interactable`** tag (Studio → *View → Tag Editor*), **or**
   - Add a boolean **attribute** named **`Interactable`** set to `true`.
3. The object must be an **unanchored** `MeshPart` or `Model` parented under
   `Workspace`. (Multi-part models are auto-welded on pickup and unwelded on drop.)
4. Play in first person, look at the object, and press **`E`**.

### Controls

| Action | Input |
| --- | --- |
| Pick up / drop | `E` |
| Drop | `Q` |
| Inspect / rotate | Hold `R` + move mouse |

All keys are configurable in `Config.luau`.

---

## How holding stays smooth (and secure)

1. Client raycasts from the camera centre and fires `PickupRequest`.
2. Server validates tag/attribute, that the object is unanchored, and that it is
   within reach of the player's head (with a small latency margin).
3. Server transfers **network ownership** to the holder, welds loose parts,
   builds the `AlignPosition` + `AlignOrientation` rig at the bounding-box centre
   (force applied at the centre of mass), and adds `NoCollisionConstraint`s
   against the holder's character.
4. Each frame the client computes the goal in front of the camera, drives the
   constraints **locally** (instant, because it owns the physics) and streams the
   goal to the server over the unreliable channel.
5. The server applies the streamed goal **clamped** to a safe radius, replicating
   the motion to every other client. A Heartbeat watchdog drops anything that
   drifts too far or whose owner/object disappears.

---

## Tuning

Open `Config.luau`. Common adjustments:

- `MaxPickupDistance` — reach.
- `HoldDistanceBase` / `HoldDistanceSizeFactor` — how far in front objects rest.
- `PositionResponsiveness` / `OrientationResponsiveness` — snappiness.
- `MaxVelocity` — anti-fling speed cap.
- `ForcePerMass` / `TorquePerMass` — strength scaling for heavy meshes.
- `RotateSensitivity` — inspect rotation speed.
- `SendInterval` — goal replication rate.
