# roblox-combat-system

A first-person item & combat system for Roblox (Luau + Rojo), built server-authoritative.

This `main` branch holds the **finalized, working code** plus the **master design blueprint**.
It is intended to be the single source of truth so multiple agents can build without
getting confused by experimental branches.

---

## What's in here

### 1. Working system (shipped) — First-Person Pickup & Inspection
A polished, physics-driven first-person pickup/inspection system, synthesised as the
"best of" 10 independently generated implementations. It is two self-contained scripts:

| File | Location | Role |
| ---- | -------- | ---- |
| `src/ServerScriptService/PickupServer.server.luau` | `ServerScriptService` | Authoritative validation, physics rig, anti-cheat |
| `src/StarterPlayer/StarterPlayerScripts/FirstPersonPickupClient.client.luau` | `StarterPlayer/StarterPlayerScripts` | First-person targeting, input, inspection, local steering |

`default.project.json` maps these into Roblox for [Rojo](https://rojo.space/).

**How it works**
* The server validates a pickup request, transfers **network ownership** of the assembly
  to the holder, and builds an `AlignPosition` + `AlignOrientation` rig in `OneAttachment`
  mode. The owning client then steers the constraint goals locally every frame — zero
  perceived lag — and the motion replicates to everyone for free (no per-frame remotes).
* **Blender-safe holding:** objects are carried by their visual bounding-box centre
  (`Model:GetBoundingBox()`) with pivot correction, and force is applied at the centre of
  mass, so imported meshes never hover "offset weirdly" or spin parasitically.
* **Anti-fling / anti-cheat:** finite, mass-scaled forces/torques, capped velocity,
  collision-group isolation from characters, and a server leash loop (with a grace period)
  that force-drops anything driven too far.

**Authoring interactables:** tag a `Model`/`BasePart` with the CollectionService tag
`Interactable`, or set a boolean attribute `Interactable = true`.

**Controls**

| Input | Action |
| ----- | ------ |
| `E` / `R1` | Pick up what you're looking at (or drop what you hold) |
| `Q` | Drop |
| Hold `R` / `L1` | Inspect: freeze the view and rotate the held object with the mouse |
| Mouse wheel | Push the held object further away / pull it closer |

**Tuning:** all tunables live in the `Config` table at the top of each script.

### 2. Design blueprint (roadmap) — `docs/BLUEPRINT.md`
The master design blueprint (v2, *bridged*). **Read it in full before writing new code.**
It bridges the working pickup system above with the next vision — **weapons (E to equip),
first-person viewmodel arms, and hitscan shooting with server-side anti-cheat** — and
defines the frozen RemoteEvent/module contracts, data schemas, end-to-end flows,
refinements/bug-fixes for the existing scripts, an anti-cheat checklist, and a multi-agent
parallel build plan.

> **Note for contributors:** the blueprint describes a **target modular layout**
> (`src/shared`, `src/server`, `src/client`). The shipped code currently uses the
> two-script layout above. The blueprint's "Migration Map" explains how to port the
> proven physics into the modular layout while adding guns/arms/shooting. Until that
> migration lands, the two scripts above are the authoritative working implementation.

---

## Toolchain
- Roblox · Luau · Rojo (the Git repo is the source of truth; code only).
