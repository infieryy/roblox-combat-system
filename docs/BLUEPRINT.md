# First-Person Item & Combat System — Master Design Blueprint (v2, Bridged)

> **Audience:** Written so that **up to 10 AI coding agents (in Cursor) can build this system in parallel** without colliding.
> **Read this first, in full, before writing any code.** Every contract here (RemoteEvents, module APIs, data schemas, naming) is **binding**.
>
> **Engine:** Roblox · **Language:** Luau · **Toolchain:** Rojo · **Architecture:** Server-authoritative.
>
> **What "v2 / Bridged" means:** v1 of this blueprint was written as if from scratch. In reality the repo already contains a strong, server-authoritative **first-person pickup & inspection system** (the "consensus build"). This version **bridges** that existing code with the newer vision (guns, first-person arms, hitscan shooting). The drag/physics half is **already largely built** — we *port and refine* it; the gun/arms/shooting half is **net-new**.

---

## 0. Table of Contents

1. [Current Codebase State (what already exists)](#1-current-codebase-state)
2. [Goals, Non-Goals & Locked Decisions](#2-goals-non-goals--locked-decisions)
3. [Core Architecture Principles](#3-core-architecture-principles)
4. [System Map](#4-system-map)
5. [Toolchain & Repository Layout](#5-toolchain--repository-layout)
6. [Migration Map: consensus code → modules](#6-migration-map)
7. [Global Conventions](#7-global-conventions)
8. [THE REMOTES CONTRACT](#8-the-remotes-contract)
9. [Shared Module Specs](#9-shared-module-specs)
10. [Server Module Specs](#10-server-module-specs)
11. [Client Module Specs](#11-client-module-specs)
12. [Data Schemas](#12-data-schemas)
13. [End-to-End Sequence Flows](#13-end-to-end-sequence-flows)
14. [Refinements & Bug Fixes for Existing Code](#14-refinements--bug-fixes-for-existing-code)
15. [Anti-Cheat Checklist](#15-anti-cheat-checklist)
16. [Work Packages for 10 Agents](#16-work-packages-for-10-agents)
17. [Parallel-Work & Merge Strategy](#17-parallel-work--merge-strategy)
18. [Testing Plan](#18-testing-plan)
19. [Glossary](#19-glossary)

---

## 1. Current Codebase State

The finalized working code now lives on **`main`** (consolidated from the consensus build, branch `cursor/master-firstperson-pickup-consensus-dd25`, commit `9767000`). It is **two self-contained scripts**:

| File | Lines | Role |
|---|---|---|
| `src/ServerScriptService/PickupServer.server.luau` | ~733 | Authoritative pickup: validation, `AlignPosition`+`AlignOrientation` rig, network-ownership transfer, collision-group isolation, welding, leash anti-cheat loop. |
| `src/StarterPlayer/StarterPlayerScripts/FirstPersonPickupClient.client.luau` | ~496 | First-person targeting/highlight, **E** to pick up, **Q** drop, hold **R** inspect-rotate, scroll distance, local constraint steering. |

### What the consensus build already does well (keep all of this)
- **Physics drag without teleporting:** `AlignPosition` + `AlignOrientation` in `OneAttachment` mode. ✅ (Goal 1)
- **Network ownership → the holder** for zero-lag local steering; returned on drop. ✅
- **Anti-fling:** finite, mass-scaled `MaxForce`/`MaxTorque`, hard `MaxVelocity` cap. ✅
- **Won't shove the player:** `PickupHeldObjects` collision group, non-collidable with characters. ✅
- **Anti-float-away / anti-cheat:** server leash loop with grace period. ✅
- **Server-authoritative validation:** re-derives target, checks distance + mass + ownership. ✅
- **Blender-safe centering:** bounding-box pivot correction. ✅

### What it does NOT do (the bridge work)
- ❌ No **item-type distinction** — everything is one `Interactable` kind picked up with **E**.
- ❌ No **weapons** (equip/hold-in-hands), no **first-person arms/viewmodel**, no **shooting**, no **ammo**.
- ⚠️ **Behavior conflict to resolve:** consensus uses **E to pick up props** and a *carry/inspect* model; the new vision is **props = mouse-grab-and-fling (no E)** and **E = equip a gun**.

---

## 2. Goals, Non-Goals & Locked Decisions

### Unified goals
1. **Dragging (props):** physics-based grab that never glitches/floats/crashes into the player. → *Adapt the consensus drag rig.*
2. **Switch logic:** on **E**, equip a **gun** (snaps to hands). **Props cannot use E** — mouse only (grab + fling, *Dusty Trip* style).
3. **First-person arms:** viewmodel arms + gun on screen, smooth sway/bob. → *Net-new.*
4. **Shooting & anti-cheat:** hitscan on click; server re-validates ammo, fire-rate, line-of-sight. → *Net-new, reusing consensus anti-cheat discipline.*

### Locked decisions
| # | Decision | Source |
|---|---|---|
| 1 | Weapons are **hitscan**. | stakeholder |
| 2 | Dragged props **do not rotate** (position only; orientation held steady). | stakeholder |
| 3 | **One item at a time** — equipping a gun auto-drops a held prop and vice-versa. | stakeholder |
| 4 | Toolchain is **Rojo**; the Git repo is code-only source of truth. | stakeholder |
| 5 | **Props = mouse-grab-and-fling, no E.** E is reserved for equipping guns. | bridge decision |
| 6 | Adopt the consensus pattern: **server builds the drag rig; the owning client steers the constraint goals.** | bridge decision (supersedes v1) |
| 7 | The consensus **inspect-rotate** feature is **kept but gated off** (`Config.Drag.enableInspect = false`) for a future v2. | bridge decision (honours #2) |

### Non-Goals (v1)
- Projectile weapons (hitscan only), rotating held props, multi-slot inventory, cinematic reloads, networked lag-compensation/rewind (designed-for, not built — see §15).

---

## 3. Core Architecture Principles

1. **Client requests & predicts. Server decides & owns truth.** (Already how the consensus build works — extend it everywhere.)
2. **Client sends intents, never results.** Fire = `(origin, direction)`, never "I hit X for Y."
3. **Authoritative state on the server:** `PlayerHoldState`, `AmmoLedger`, health, network ownership.
4. **One door per concern** — only the RemoteEvents in §8. No agent adds a remote without updating §8 in the same PR.
5. **Shared truth in `shared/`** — `ItemRegistry`, `Config`, `Types`, `GeometryUtil`. **No mirrored config** (the consensus build duplicates config/geometry across both scripts — §14 fixes this).
6. **Fail safe, fail quiet** on rejected client input.
7. **Frozen contracts.** Public APIs and remote payloads here are binding.

---

## 4. System Map

```
┌─────────────────────────── CLIENT (per player) ───────────────────────────┐
│  init.client → starts controllers                                          │
│                                                                            │
│  InteractionController  ── raycast crosshair (ported from consensus),      │
│        │                    ask ItemRegistry, route:                       │
│        │                      Weapon → "E to Equip" prompt                 │
│        │                      Prop   → mouse-grab (DragController)         │
│        ├── DragController       (steers server-built AlignPosition;        │
│        │                         mouse-hold to grab, release = fling)      │
│        ├── ViewmodelController  (arms+gun render, sway, bob)   [NEW]       │
│        └── WeaponController      (click→predict→FireRequest)   [NEW]       │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │  RemoteEvents (§8) — the ONLY doors
┌───────────────────────────────────┴────────────────────────────────────────┐
│                              SERVER (referee)                                 │
│  init.server → creates Remotes, registers collision groups, starts services │
│                                                                              │
│  DragService(ported)   EquipService[NEW]   WeaponService[NEW]                │
│        \                    |                  /                              │
│         └──→ PlayerHoldState (one active hold: Weapon | Prop | None) ←──┘    │
│                         AmmoLedger[NEW] (authoritative ammo)                  │
│           PhysicsAuthority (collision groups + network ownership, ported)     │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │
┌───────────────────────────────────┴────────────────────────────────────────┐
│  SHARED (ReplicatedStorage.Shared)                                           │
│  ItemRegistry · Config · Types · GeometryUtil (de-duplicated from consensus) │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Toolchain & Repository Layout

The repo is code-only; RemoteEvents are created at runtime. Physical assets (gun models, arms rig) live in a Studio place file referenced by name.

### Target file tree (authoritative)
```
roblox-combat-system/
├── default.project.json
├── .gitignore
├── README.md
├── docs/BLUEPRINT.md            -- (this file)
└── src/
    ├── shared/                  -- → ReplicatedStorage.Shared
    │   ├── ItemRegistry.luau
    │   ├── Config.luau
    │   ├── Types.luau
    │   └── GeometryUtil.luau    -- ported from consensus (getParts, primaryPart, bbox, visualCenter…)
    ├── server/                  -- → ServerScriptService.Server
    │   ├── init.server.luau
    │   ├── Remotes.luau
    │   ├── PhysicsAuthority.luau-- collision groups + network ownership (ported)
    │   ├── PlayerHoldState.luau
    │   ├── AmmoLedger.luau
    │   ├── EquipService.luau
    │   ├── DragService.luau     -- ported core of PickupServer (rig, leash, drop, validation)
    │   └── WeaponService.luau
    └── client/                  -- → StarterPlayerScripts.Client
        ├── init.client.luau
        ├── RemotesClient.luau
        ├── InteractionController.luau -- ported targeting/highlight/prompt + routing
        ├── DragController.luau        -- ported steering (mouse-driven, no rotation)
        ├── ViewmodelController.luau
        └── WeaponController.luau
```

> **Note:** the consensus files live at `src/ServerScriptService/…` and `src/StarterPlayer/…`. The refactor relocates logic into `src/server` / `src/client` / `src/shared`. The old two-file layout is replaced; do not keep both.

### `default.project.json` (target)
```jsonc
{
  "name": "roblox-combat-system",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": { "Shared": { "$path": "src/shared" } },
    "ServerScriptService": { "Server": { "$path": "src/server" } },
    "StarterPlayer": { "StarterPlayerScripts": { "Client": { "$path": "src/client" } } }
  }
}
```

---

## 6. Migration Map

How the consensus code becomes the new modules. **Reuse the logic; don't rewrite the physics.**

| Consensus source (file → function) | New home | Change required |
|---|---|---|
| `PickupServer` `getParts/getPrimaryPart/getBoundingBox/getVisualCenter/getBoundingRadius` | `shared/GeometryUtil` | Move verbatim; client now `require`s the same copy (kills duplication). |
| `PickupServer` `Config` table | `shared/Config.Drag` + `Config.CollisionGroups` | Single source; client reads same values (no mirror). |
| `PickupServer` `ensureCollisionGroups/assignCharacterGroup/apply/restoreCollisionGroup` | `server/PhysicsAuthority` | Move verbatim. |
| `PickupServer` `giveOwnership/resetOwnership` | `server/PhysicsAuthority` | Move verbatim. |
| `PickupServer` `createHoldRig` (AlignPosition+AlignOrientation, mass-scaled forces, ApplyAtCenterOfMass) | `server/DragService` | Keep; for no-rotation, AlignOrientation goal stays fixed at grab orientation (no per-frame rotation input). |
| `PickupServer` `onPickupRequest` validation (distance/mass/ownership/weld/unanchor) | `server/DragService.onDragStart` | Keep validation; integrate `PlayerHoldState.setProp` (auto-unequip gun); trigger is now a mouse-grab request, not E. |
| `PickupServer` `dropObject` | `server/DragService.drop` | Keep; route through `PlayerHoldState.clear`. |
| `PickupServer` `startLeashLoop` | `server/DragService` | Keep (the real anti-cheat for client-owned parts). |
| `PickupServer` lifecycle (`onCharacterAdded/onPlayerAdded`, respawn/death drop) | `server/init.server` + services | Keep behavior. |
| Client `updateTargeting/setTarget/resolveInteractable/UI` | `client/InteractionController` | Keep targeting+highlight; **route by item type** (Weapon→prompt, Prop→grab). |
| Client `steerHold` | `client/DragController` | Keep position steering; **drop inspect-rotate path** (gate behind `Config.Drag.enableInspect`); grab is **mouse-hold**, release = drop+fling. |
| Client `beginHold/endHold`, scroll distance, raycast filter | `client/DragController` | Keep. |
| Client `ForceFirstPerson` / camera handling | `client/ViewmodelController` owns first-person + arms going forward | Keep LockFirstPerson; arms make it look right. |
| Consensus remotes `PickupRequest/DropRequest/PickupGranted/PickupEnded` | `Drag*` remotes in §8 | Rename per §8; same shapes (server still passes constraint refs to client). |

---

## 7. Global Conventions

- Files `PascalCase.luau`; folder bootstraps `init.server.luau`/`init.client.luau`.
- Functions/methods `camelCase`; types `PascalCase`; constants `SCREAMING_SNAKE_CASE` or in `Config`.
- **No magic numbers in logic** — everything tunable lives in `Config`.
- `--!strict` at the top of every file; cross-module shapes from `shared/Types`.
- Remotes accessed only via `Remotes`/`RemotesClient`, never ad-hoc `WaitForChild`.
- `task.wait/spawn/defer` only (no deprecated `wait/spawn`).
- `warn("[Module] …")` for recoverable issues; never `error()` on player-input paths.
- Comments explain *why*; mark open contract points `-- TODO(contract):`.

---

## 8. THE REMOTES CONTRACT

All `RemoteEvent`s in a single runtime folder `ReplicatedStorage.ItemSystemRemotes` (renames the consensus `PickupSystemRemotes`). Server `Remotes.luau` creates them; client `RemotesClient.luau` waits for them. **No `RemoteFunction`s** (avoid client-yield exploits).

### Drag/prop (ported from consensus, renamed)
| Name | Direction | Payload | Notes |
|---|---|---|---|
| `DragStartRequest` | C→S | `propInstance: Instance` | was `PickupRequest`. Player mouse-pressed a prop. |
| `DragEndRequest` | C→S | *(none)* | was `DropRequest`. Mouse released. |
| `DragGranted` | S→C | `prop: Instance, primaryPart: BasePart, alignPosition: AlignPosition, alignOrientation: AlignOrientation` | was `PickupGranted`. **Server built the rig; client steers these refs.** |
| `DragEnded` | S→C | `prop: Instance?` | was `PickupEnded`. |

### Weapon / equip (new)
| Name | Direction | Payload | Notes |
|---|---|---|---|
| `EquipRequest` | C→S | `weaponInstance: Instance` | Player pressed **E** on a weapon. |
| `EquipResult` | S→C | `ok: boolean, weaponId: string?, ammo: number?` | On ok → show viewmodel. |
| `UnequipRequest` | C→S | *(none)* | Put gun away. |
| `HoldStateChanged` | S→C | `kind: "Weapon"\|"Prop"\|"None", instance: Instance?` | Authoritative hold change (incl. auto-drop/unequip). Overrides client prediction. |
| `FireRequest` | C→S | `origin: Vector3, direction: Vector3, clientShotId: number` | `direction` unit vector. |
| `FireResult` | S→C | `clientShotId: number, ok: boolean, ammo: number, hitPosition: Vector3?` | Authoritative ammo + confirmed impact. |
| `ShotFired` | S→Clients | `shooter: Player, origin: Vector3, hitPosition: Vector3` | Broadcast for others' tracers/impacts. |
| `ReloadRequest` | C→S | *(none)* | |
| `ReloadResult` | S→C | `ok: boolean, ammo: number` | |

### Contract rules
- Payload order/types frozen. New field ⇒ update this table same PR + `BREAKING CONTRACT` in PR title.
- `clientShotId` = monotonically increasing int per shot for reconciliation.
- `weaponId` = registry key string, not the Instance.
- Server may send unsolicited `HoldStateChanged` / `DragEnded`; clients treat as truth.
- Per-remote rate limiting on every C→S remote (`Config.Security`). **(New: the consensus had none — §14.)**

---

## 9. Shared Module Specs

### 9.1 `shared/GeometryUtil.luau` — **Owner: Agent B.** *(Ported from consensus.)*
```lua
GeometryUtil.getParts(target: Instance): { BasePart }
GeometryUtil.getPrimaryPart(target: Instance): BasePart?      -- PrimaryPart, else largest by volume
GeometryUtil.getBoundingBox(target: Instance): (CFrame, Vector3)
GeometryUtil.getVisualCenter(target: Instance): Vector3        -- Blender pivot correction
GeometryUtil.getBoundingRadius(target: Instance): number
```
Single copy used by both server (DragService) and client (Interaction/Drag). **Removes the consensus duplication.**

### 9.2 `shared/ItemRegistry.luau` — **Owner: Agent B.**
Classifies items and holds weapon defs.
```lua
ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
-- "Weapon" if ItemType attr == "Weapon"; "Prop" if ItemType == "Prop"
--   OR (backward-compat) CollectionService tag "Interactable" / attribute Interactable == true;
-- else "None".
ItemRegistry.getWeaponId(instance: Instance): string?
ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
ItemRegistry.isDraggable(instance: Instance): boolean   -- Prop & not anchored/locked
ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
```
> Backward-compat note: existing test props tagged `Interactable` keep working as **Props**.

### 9.3 `shared/Config.luau` — **Owner: Agent B.** Frozen keys (values tunable). Merges consensus drag tunables.
```lua
Config = {
  Drag = {
    -- ported from consensus PickupServer.Config:
    maxPickupDistance = 12, serverDistanceTolerance = 4,
    maxHoldDistance = 14, leashGracePeriod = 0.6, leashInterval = 0.2,
    maxObjectMass = 5000, pivotCorrectionThreshold = 0.2,
    positionResponsiveness = 55, forceMultiplier = 50,
    minForce = 30000, maxForce = 8_000_000, maxVelocity = 90,
    orientationResponsiveness = 50, torqueMultiplier = 4000,
    minTorque = 40000, maxTorque = 8_000_000, maxAngularVelocity = 35,
    dropImpulseSpeed = 6,
    -- client framing:
    holdDistanceBase = 4, holdDistancePadding = 1.0,
    holdDistanceMin = 3, holdDistanceMax = 10, scrollStep = 0.75,
    -- bridge:
    enableInspect = false,           -- consensus inspect-rotate gated off (decision #7)
    flingVelocityMultiplier = 1.0,   -- emergent fling on release
  },
  Viewmodel = { swayAmount=…, swaySpeed=…, bobAmount=…, bobSpeed=…,
                baseOffsetCFrame=…, springDamping=…, springFrequency=… },
  Weapon = { serverRayLengthPadding=…, maxAimDeviationDegrees=… },
  Security = {
    fireRequestCooldownMs=…, dragRequestCooldownMs=…, equipRequestCooldownMs=…,
    maxEquipDistance=…, maxDragStartDistance = 12 + 4, -- mirror drag distance+tolerance
  },
  CollisionGroups = { heldObjects="PickupHeldObjects", characters="PickupCharacters", default="Default" },
  RemotesFolderName = "ItemSystemRemotes",
}
```

### 9.4 `shared/Types.luau` — **Owner: Agent B.** Exports `WeaponDef`, `HoldState`, `HoldRig` (see §12).

---

## 10. Server Module Specs

### 10.0 `server/init.server.luau` — **Owner: Agent C.**
Requires `Remotes` (build folder), `PhysicsAuthority.registerCollisionGroups()`, then `.start()`s in order: `AmmoLedger`, `PlayerHoldState`, `DragService`, `EquipService`, `WeaponService`. Wires `PlayerAdded`/`CharacterAdded` (assign collision group, drop-on-death/respawn — ported), `PlayerRemoving` cleanup.

### 10.1 `server/Remotes.luau` — **Owner: Agent C.** Creates `ItemSystemRemotes` + all §8 events; returns typed table.

### 10.2 `server/PhysicsAuthority.luau` — **Owner: Agent C.** *(Ported.)*
```lua
registerCollisionGroups()        -- heldObjects × characters = non-collidable (ported ensureCollisionGroups)
assignCharacterToGroup(character) -- ported assignCharacterGroup
applyHeldGroup(target): snapshot  -- ported applyCollisionGroup
restoreGroups(snapshot)           -- ported restoreCollisionGroups
giveOwnership(part, player): boolean -- ported (keeps CanSetNetworkOwnership guard)
returnOwnership(part)             -- ported (SetNetworkOwnershipAuto)
```

### 10.3 `server/PlayerHoldState.luau` — **Owner: Agent D.** *(New — unifies the one-item rule.)*
```lua
get(player): HoldState
setWeapon(player, weapon, weaponId): HoldState  -- returns PREVIOUS hold (caller runs teardown)
setProp(player, prop): HoldState                -- returns PREVIOUS hold
clear(player): HoldState
isHolding(player): boolean
```
Rules: `setWeapon`/`setProp` internally `clear` first and **return the previous hold** so the caller runs the right teardown (`DragService.forceRelease` or `EquipService.forceUnequip`). Always fires `HoldStateChanged`. **Only this module mutates hold state.**
> Replaces the consensus `sessions[player]` single-object guard with a unified weapon|prop slot. DragService keeps its own per-player **rig session** (constraints/welds/snapshots), but the *authoritative "what are you holding"* lives here.

### 10.4 `server/AmmoLedger.luau` — **Owner: Agent E.** *(New — anti-cheat core.)*
```lua
onEquip(player, weaponId)   -- init to maxAmmo if first time
get(player, weaponId): number
canFire(player, weaponId): boolean
consumeRound(player, weaponId): boolean
reload(player, weaponId): number
clearPlayer(player)
```
Only module allowed to mutate ammo.

### 10.5 `server/DragService.luau` — **Owner: Agent G.** *(Ported core of `PickupServer`.)*
Handles `DragStartRequest`, `DragEndRequest`. Keeps the consensus **rig session** (`HoldRig`, welds, anchored/collision snapshots, leash `breachTime`).
**`onDragStart(player, prop)` pipeline (ported + bridged):**
1. Rate-limit (`Config.Security.dragRequestCooldownMs`). *(new guard)*
2. `ItemRegistry.classify(prop) == "Prop"` and `isDraggable`. *(was: any Interactable)*
3. Re-derive on server, ownership-free, alive check, distance (visual-center, ported), mass ≤ `maxObjectMass`.
4. `PlayerHoldState.setProp` → if previous was a Weapon, `EquipService.forceUnequip(player)`.
5. unanchor + weld + `PhysicsAuthority.applyHeldGroup` + `giveOwnership` + `createHoldRig` (ported).
6. Fire `DragGranted(prop, primary, alignPosition, alignOrientation)`.
**`onDragEnd` / `drop`:** ported teardown (destroy rig, restore groups/anchors, return ownership, optional drop impulse capped by `maxVelocity` — §14) + `PlayerHoldState.clear`.
**Leash loop:** ported `startLeashLoop` (the real anti-cheat for client-owned parts).
**Cross-service:** expose `forceRelease(player)` (called by EquipService).
> No-rotation (decision #2): `createHoldRig` still creates `AlignOrientation`, but the orientation goal is **set once** to grab-time orientation and not driven per-frame. Inspect-rotate code path stays gated by `Config.Drag.enableInspect`.

### 10.6 `server/EquipService.luau` — **Owner: Agent F.** *(New.)*
Handles `EquipRequest`, `UnequipRequest`.
Pipeline: rate-limit → `classify=="Weapon"` → `weaponId`/def exist → distance ≤ `maxEquipDistance` → not equipped by another → `PlayerHoldState.setWeapon` (prev Prop ⇒ `DragService.forceRelease`) → `AmmoLedger.onEquip` → attach weapon to character (authoritative) → `EquipResult(true, weaponId, ammo)`. Reject ⇒ `EquipResult(false)`.
Expose `forceUnequip(player)` (called by DragService).

### 10.7 `server/WeaponService.luau` — **Owner: Agent H.** *(New — hitscan.)*
Handles `FireRequest`, `ReloadRequest`.
`onFire(player, origin, direction, clientShotId)`:
1. Rate-limit (`fireRequestCooldownMs`).
2. `PlayerHoldState.get` is Weapon; resolve `weaponId`/def.
3. Per-weapon fire-rate (server timestamp ≥ `1/def.fireRateRps`).
4. `AmmoLedger.canFire` → `consumeRound`; else `FireResult(id,false,0)`.
5. Plausibility: angle(`direction`, real look vector) ≤ `maxAimDeviationDegrees`; `origin` near head.
6. **Authoritative raycast** from trusted head origin along `direction`, length `def.range`, filter excluding shooter → enforces LoS / no-wall-penetration.
7. Damage humanoid if hit; `FireResult(id,true,newAmmo,hitPos)` + broadcast `ShotFired`.
`onReload`: validate held → after `def.reloadTime` → `AmmoLedger.reload` → `ReloadResult`. Leave `-- TODO(v2: lagcomp)` anchor.

---

## 11. Client Module Specs

### 11.0 `client/init.client.luau` — **Owner: Agent C.** Requires `RemotesClient`; `.start()`s `ViewmodelController`, `InteractionController`, `DragController`, `WeaponController`.

### 11.1 `client/RemotesClient.luau` — **Owner: Agent C.** Waits for `ItemSystemRemotes`; returns typed handles.

### 11.2 `client/InteractionController.luau` — **Owner: Agent I.** *(Ported targeting + new routing.)*
- Ported: per-frame camera raycast, highlight, reticle, prompt, `resolveInteractable`, raycast filter (excludes character + held).
- **Routing by `ItemRegistry.classify`:**
  - **Weapon** → show "E to Equip"; on **E** → `EquipRequest(weapon)`.
  - **Prop** → no E; on **mouse-button-down** over a draggable prop → `DragController.beginDrag(prop)`. (Only when empty-handed.)
  - **None** → clear prompt/highlight.
- Reacts to `HoldStateChanged` for HUD/crosshair state.
> Replaces the consensus "E picks up everything." Empty-handed left-click grabs a prop; with a gun equipped, left-click is owned by `WeaponController` (fire).

### 11.3 `client/DragController.luau` — **Owner: Agent J.** *(Ported steering, mouse-driven, no rotation.)*
- `beginDrag(prop)` → `DragStartRequest(prop)`. On `DragGranted(...)`, store the **server-provided** `alignPosition`/`alignOrientation` refs.
- Each `RenderStepped` while dragging: set `alignPosition.Position` to a point `holdDistance` in front of the camera (ported `steerHold` minus inspect); `alignOrientation.CFrame` held at the grab-time goal (no per-frame rotation). Scroll adjusts `holdDistance` (ported).
- Release mouse → `endDrag()` → `DragEndRequest`. **Fling** is emergent from retained velocity; optional `flingVelocityMultiplier`.
- Auto-release if prop exceeds `maxHoldDistance` (mirrors server leash). React to `DragEnded`/`HoldStateChanged("None")`.
- Inspect-rotate path present but gated by `Config.Drag.enableInspect`.
- Public: `beginDrag`, `endDrag`, `isDragging()`.

### 11.4 `client/ViewmodelController.luau` — **Owner: Agent K.** *(New.)*
- Owns first-person lock (ported `LockFirstPerson`).
- State machine `Empty ↔ Weapon`. On `EquipResult(true, weaponId)` / `HoldStateChanged("Weapon")` build/show arms+gun for `def.viewmodelName`; on `None` hide.
- `RenderStepped`: base = `camera.CFrame * Config.Viewmodel.baseOffsetCFrame`; layer **look-sway** (camera-rotation delta, spring-smoothed) + **walk-bob** (sine × humanoid speed).
- Cosmetic only; never authoritative for aim. Exposes `getMuzzlePosition()`, `playFireKick()`.

### 11.5 `client/WeaponController.luau` — **Owner: Agent L.** *(New.)*
- Tracks predicted ammo/equip (synced from `EquipResult`/`FireResult`/`HoldStateChanged`).
- On mouse-click (weapon held, off cooldown, predicted ammo>0): predict (kick/flash/tracer/sound, ammo--), raycast from camera, `FireRequest(origin, direction, clientShotId)`.
- On `FireResult`: set ammo to authoritative; if `ok=false`, roll back visuals/ammo.
- On `ShotFired` (others): render tracer/impact. Handles reload + HUD.

---

## 12. Data Schemas

### Item attributes (Studio-set; read by `ItemRegistry`)
| Attribute | Type | On | Meaning |
|---|---|---|---|
| `ItemType` | string | interactables | `"Weapon"` or `"Prop"`. |
| `WeaponId` | string | weapons | registry key, e.g. `"pistol_9mm"`. |
| `Interactable` | bool/tag | props (legacy) | back-compat → treated as `Prop`. |
| `Draggable` | bool | props (optional) | default true; false locks. |
| `PickupHeldBy` | number | runtime | UserId stamp while held (ported `HeldByAttribute`). |

### `Types.WeaponDef`
```lua
export type WeaponDef = {
  weaponId: string, displayName: string,
  damage: number, maxAmmo: number, fireRateRps: number,
  range: number, spread: number, reloadTime: number, viewmodelName: string,
}
```
### `Types.HoldState`
```lua
export type HoldState = { kind: "Weapon"|"Prop"|"None", instance: Instance?, weaponId: string? }
```
### `Types.HoldRig` (ported)
```lua
export type HoldRig = { attachment: Attachment, alignPosition: AlignPosition, alignOrientation: AlignOrientation }
```

---

## 13. End-to-End Sequence Flows

### A) Grab & fling a prop (mouse, ported + bridged)
```
Empty-handed, looking at Prop → InteractionController (no E prompt)
Mouse-down → DragController.beginDrag → DragStartRequest(prop)
Server DragService: classify==Prop → validate(distance/mass) → PlayerHoldState.setProp
  (if prev was Weapon → EquipService.forceUnequip)
  → weld+unanchor+collisiongroup+giveOwnership+createHoldRig
  → DragGranted(prop, primary, alignPosition, alignOrientation)
Client: each frame set alignPosition.Position in front of camera (no rotation)
Mouse-up → endDrag → DragEndRequest → server drop (return ownership, restore, clear)
(Release momentum = fling)
```

### B) Equip a weapon (E, new)
```
Looking at Weapon → InteractionController shows "E to Equip"
Press E → EquipRequest(weapon)
Server EquipService: classify==Weapon → validate → PlayerHoldState.setWeapon
  (if prev was Prop → DragService.forceRelease) → AmmoLedger.onEquip → attach
  → EquipResult(true, weaponId, ammo) + HoldStateChanged("Weapon", weapon)
Client: ViewmodelController shows arms+gun; WeaponController arms
```

### C) Fire (hitscan, new)
```
Click (weapon held, ammo>0, off cooldown) → predict locally → FireRequest(origin,dir,id)
Server WeaponService: rate-limit → hold==Weapon → fire-rate → AmmoLedger.consumeRound
  → plausibility → authoritative raycast (LoS/walls/range) → damage
  → FireResult(id,true,ammo,hitPos) + broadcast ShotFired
Client: reconcile ammo; others render tracer
```

---

## 14. Refinements & Bug Fixes for Existing Code

Concrete fixes to apply while porting the consensus build (each maps to an owner in §16):

1. **De-duplicate mirrored config & geometry (high value).** The two consensus scripts each redefine `Config` and `getBoundingBox`/`isInteractable`/`resolveInteractable`. Drift here = subtle desync bugs. → Move to `shared/Config` + `shared/GeometryUtil` + `shared/ItemRegistry`; both sides require one copy. *(Owner B/C/G/I/J.)*
2. **Add per-remote rate limiting (security gap).** `PickupRequest`/`DropRequest` have no throttle; only a single-session guard. → Add `Config.Security.*CooldownMs` checks in every C→S handler. *(Owners F/G/H.)*
3. **Cap the drop impulse.** `dropObject` sets `AssemblyLinearVelocity = look * DropImpulseSpeed` directly, bypassing the `MaxVelocity` guard. → Clamp drop/fling velocity to `Config.Drag.maxVelocity`. *(Owner G.)*
4. **Inspect-mode camera fight.** `Scriptable` + per-frame CFrame pin at `Camera+1` can jitter against `LockFirstPerson`. Since inspect is gated off for v1 (decision #7), the risk is parked; if re-enabled, drive it through the viewmodel/camera owner instead of a second binding. *(Owner J/K, v2.)*
5. **Weld safety for jointed/animated models.** `weldAssembly` rigidly welds parts not already connected; a `Motor6D`-rigged prop could behave oddly. → Skip/limit welding when the model has animator joints, or document props must be static meshes. *(Owner G.)*
6. **`PickupHeldBy` replication race.** Two clients may briefly target the same prop before the attribute replicates; server already wins the actual grab, so keep server authority and treat client highlight as cosmetic (no fix needed beyond a comment). *(Owner G/I.)*
7. **One-item unification.** Consensus `sessions[player]` only knew about props. Route everything through `PlayerHoldState` so a gun and a prop can never coexist. *(Owners D/F/G.)*
8. **Strict-typing the remote payloads.** When moving to typed `Remotes` modules, annotate handlers so a malformed `FireRequest`/`DragStartRequest` is type-guarded (consensus already does `typeof(requested)~="Instance"` — keep that pattern everywhere). *(Owners C/F/G/H.)*

---

## 15. Anti-Cheat Checklist

- [ ] Client sends only `origin/direction/clientShotId` for shots — never damage/victim.
- [ ] Ammo mutates **only** in `AmmoLedger` (server). (No infinite ammo.)
- [ ] Server enforces per-weapon fire rate via timestamps. (No rapid-fire.)
- [ ] Server does its **own** raycast from a trusted origin. (No shoot-through-walls / teleport-aim.)
- [ ] Server verifies held weapon via `PlayerHoldState`. (No phantom-weapon fire.)
- [ ] Distance checks on equip and drag-start. (No remote grabbing — *ported.*)
- [ ] Network ownership returns to server on release. (*Ported.*)
- [ ] Leash loop drops over-driven held parts. (*Ported.*)
- [ ] Per-remote rate limiting on every C→S remote. (*New — §14.2.*)
- [ ] Plausibility: `direction` within `maxAimDeviationDegrees` of look vector.
- [ ] `HoldStateChanged`/`DragEnded` from server override client prediction.
- [ ] `-- TODO(v2: lagcomp)` anchor left in `WeaponService`.

---

## 16. Work Packages for 10 Agents

Each agent writes ONLY its owned files, against the frozen contracts here. "Port" = adapt proven consensus logic; "New" = greenfield.

| Agent | Package | Owns | Deps | Type |
|---|---|---|---|---|
| **1 (A+C)** | Scaffolding + Foundation | `default.project.json`, `.gitignore`, `README`, `src/{server,client}` bootstraps, `server/Remotes.luau`, `server/PhysicsAuthority.luau`, `client/RemotesClient.luau` | none | Port (physics) + new wiring |
| **2 (B)** | Shared core | `shared/GeometryUtil.luau`, `ItemRegistry.luau`, `Config.luau`, `Types.luau` | 1 | Port + new |
| **3 (D)** | Hold state | `server/PlayerHoldState.luau` | 1,2 | New |
| **4 (E)** | Ammo ledger | `server/AmmoLedger.luau` | 2 | New |
| **5 (F)** | Equip service | `server/EquipService.luau` | 1,2,3,4 | New (+ `forceUnequip`) |
| **6 (G)** | Drag service | `server/DragService.luau` | 1,2,3 | **Port core of `PickupServer`** (+ `forceRelease`, fixes §14.2/3/5) |
| **7 (H)** | Weapon service | `server/WeaponService.luau` | 1,2,3,4 | New |
| **8 (I+J)** | Interaction + client drag | `client/InteractionController.luau`, `client/DragController.luau` | 1,2 | **Port targeting/steering** + new routing |
| **9 (K)** | Viewmodel | `client/ViewmodelController.luau` | 1,2 | New |
| **10 (L)** | Client weapon | `client/WeaponController.luau` | 1,2,9 | New |

### Cross-service teardown contract (the #1 parallel hazard)
`PlayerHoldState.setWeapon/setProp` returns the **previous** hold; the caller invokes the counterpart's public teardown: `DragService.forceRelease(player)` or `EquipService.forceUnequip(player)`. Both functions are frozen API; each agent stubs theirs (warn + no-op) until the other lands.

---

## 17. Parallel-Work & Merge Strategy

1. **Land foundation first:** Agent 1 (scaffolding/foundation) + Agent 2 (shared core). They establish the modular tree the consensus code is ported into. Everyone else codes against documented interfaces meanwhile.
2. **Source material:** porting agents (1, 6, 8) pull logic from the finalized scripts on `main` (`src/ServerScriptService/PickupServer.server.luau`, `src/StarterPlayer/.../FirstPersonPickupClient.client.luau`). Do not invent new physics — move the proven code.
3. **One file = one owner** (§16 map). Need a change in someone else's file? Comment + `-- TODO(contract)`, don't edit.
4. **Contracts append-only** during the sprint; a §8/API change ⇒ `BREAKING CONTRACT` PR updating this doc.
5. **Stubs over blocking** when a dep isn't merged.
6. **Integration owner:** Agent 1 owns final `init` wiring order + resolves the consensus→modular relocation (deleting the old two-file layout once parity is confirmed).
7. **DoD per PR:** compiles `--!strict`, honors signatures verbatim, has a `-- Module:` header, passes its §18 tests.

---

## 18. Testing Plan

Test in Studio via Rojo. Minimum bars:
- **Shared (2):** `classify` returns correct types incl. legacy `Interactable`→Prop; `GeometryUtil` matches consensus behavior on a Blender-pivot mesh; `Config` keys present.
- **Foundation (1):** `ItemSystemRemotes` has all §8 events; collision groups exist; held×character non-collidable.
- **HoldState (3):** weapon→prop transition clears weapon and returns prior hold; `HoldStateChanged` fires.
- **Ammo (4):** `consumeRound` to 0 then false; `reload` refills; per player+weapon isolation.
- **Drag (6/8):** *regression vs consensus* — prop follows mouse smoothly, never enters player, auto-releases past max distance, release flings, heavy/anchored rejected, **no E needed**, **left-click grabs**.
- **Equip (5):** E equips; E/grab while holding the other auto-swaps (one-item); far weapon rejected.
- **Weapon (7/10):** firing decrements server ammo; faster-than-RoF rejected; target behind wall takes no damage; predicted ammo reconciles; `clientShotId` matches.
- **Viewmodel (9):** arms appear first-person, sway on look, bob on walk, hidden when empty.
- **Anti-cheat (cross):** forged `FireRequest` (bad dir / no weapon / spam) rejected; forged equip/grab at distance rejected.

Headline manual playtest: 2 players — one shoots, one hides behind a wall (no damage); one grabs/flings a prop while the other watches it replicate.

---

## 19. Glossary

- **Consensus build:** the existing 2-script pickup system on `cursor/master-firstperson-pickup-consensus-dd25` we port from.
- **Hitscan:** instantaneous ray-based hit detection.
- **Viewmodel:** camera-attached cosmetic arms+gun shown only to the local player.
- **Network ownership:** which machine simulates a part; granted to the dragger, returned on release.
- **AlignPosition/AlignOrientation:** constraints pulling a part to a goal; server-built, client-steered.
- **PlayerHoldState:** server's single source of truth for what each player holds (one item max).
- **AmmoLedger:** server's authoritative, sole ammo mutator.
- **Leash loop:** server sweep that force-drops held parts driven too far (anti-cheat for client-owned physics).
- **Prop:** draggable physics object (mouse-grab + fling, no E).
- **Weapon:** equippable hitscan gun (E to equip, click to fire).

---

*End of blueprint v2. Port the proven drag physics; build guns/arms/shooting on top; keep authority on the server.*
