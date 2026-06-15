# roblox-combat-system

## First-Person Pickup & Inspection System (Master Consensus Build)

A polished, physics-driven first-person pickup/inspection system for Roblox,
synthesised as the "best of" 10 independently generated implementations. The
whole system is just **two self-contained scripts**:

| File | Location | Role |
| ---- | -------- | ---- |
| `src/ServerScriptService/PickupServer.server.luau` | `ServerScriptService` | Authoritative validation, physics rig, anti-cheat |
| `src/StarterPlayer/StarterPlayerScripts/FirstPersonPickupClient.client.luau` | `StarterPlayer/StarterPlayerScripts` | First-person targeting, input, inspection, local steering |

A `default.project.json` is included so the system can be synced/built with
[Rojo](https://rojo.space/).

### How it works

* **Smooth-feel architecture (the consensus winner).** The server validates a
  pickup request, transfers **network ownership** of the assembly to the
  holder, and builds a modern `AlignPosition` + `AlignOrientation` rig in
  `OneAttachment` mode. The owning client then steers the constraint goals
  locally every frame, so the drag is simulated on the holder's own machine —
  **zero perceived lag** — and replicates to everyone else for free. No
  per-frame remotes required.

* **Blender-safe holding.** Imported meshes frequently have an off-centre
  pivot/origin. The object is carried by its **visual bounding-box centre**
  (computed from real geometry via `Model:GetBoundingBox()`), with a dynamic
  pivot-correction heuristic that snaps to the box centre when the pivot drifts
  too far from it — so custom meshes never hover "offset weirdly". The linear
  force is applied at the **centre of mass** (`ApplyAtCenterOfMass`) so an
  asymmetric COM can't induce a parasitic spin while dragging.

* **Anti-fling / anti-cheat.** Forces and torques are finite and scaled by
  mass, velocities are capped, held objects are isolated from characters via
  collision groups, and a server leash loop (with a short grace period)
  force-drops anything driven too far.

### Authoring interactables

Tag a `Model` or `BasePart` with the CollectionService tag **`Interactable`**,
or set a boolean attribute **`Interactable = true`** on it. Either works.

### Controls

| Input | Action |
| ----- | ------ |
| `E` / `R1` | Pick up what you're looking at (or drop what you hold) |
| `Q` | Drop |
| Hold `R` / `L1` | Inspect: freeze the view and rotate the held object with the mouse |
| Mouse wheel | Push the held object further away / pull it closer |

### Tuning

All tunables live in the `Config` table at the top of each script. The shared
values (tag/attribute, keys, distances) are mirrored in both scripts and must
be kept in sync if changed.
