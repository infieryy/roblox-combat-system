# First-Person Item & Combat System — Master Design Blueprint

> **Audience:** This document is written so that **up to 10 AI coding agents (in Cursor) can build this system in parallel** without colliding.
> **Read this first, in full, before writing any code.** Every contract here (RemoteEvents, module APIs, data schemas, naming) is **binding**. Do not invent alternative names or payloads. If a contract is ambiguous, prefer the literal text here and leave a `-- TODO(contract):` comment rather than guessing.
>
> **Engine:** Roblox · **Language:** Luau · **Toolchain:** Rojo · **Architecture:** Server-authoritative.

---

## 0. Table of Contents

1. [Goals & Non-Goals](#1-goals--non-goals)
2. [Core Architecture Principles](#2-core-architecture-principles)
3. [System Map](#3-system-map)
4. [Toolchain & Repository Layout](#4-toolchain--repository-layout)
5. [Global Conventions (naming, style, errors)](#5-global-conventions)
6. [THE REMOTES CONTRACT (read carefully)](#6-the-remotes-contract)
7. [Shared Module Specs](#7-shared-module-specs)
8. [Server Module Specs](#8-server-module-specs)
9. [Client Module Specs](#9-client-module-specs)
10. [Data Schemas](#10-data-schemas)
11. [End-to-End Sequence Flows](#11-end-to-end-sequence-flows)
12. [Anti-Cheat Checklist](#12-anti-cheat-checklist)
13. [Work Packages for 10 Agents](#13-work-packages-for-10-agents)
14. [Parallel-Work & Merge Strategy](#14-parallel-work--merge-strategy)
15. [Testing Plan](#15-testing-plan)
16. [Glossary](#16-glossary)

---

## 1. Goals & Non-Goals

### Goals
- A polished **first-person** experience: viewmodel arms + gun on screen with smooth sway/bob.
- **Two interaction modes**, decided by item type:
  - **Weapons** → press **E** to equip (snaps into hands).
  - **Props** → **mouse-drag only** (grab, move, fling — *A Dusty Trip* feel). No E.
- **Physics-based dragging** that never glitches, floats away, or shoves the player.
- **Hitscan** shooting on mouse click, with **full server-side validation** (no infinite ammo, no shooting through walls, no fire-rate abuse).
- **One item at a time** per player, enforced authoritatively on the server.

### Non-Goals (explicitly out of scope for v1)
- Projectile/ballistic weapons (hitscan only).
- Rotating held props (move only; rotation deferred).
- Inventory/hotbar with multiple stored weapons (one active hold only).
- Reloading animations beyond a basic ammo refill (basic reload allowed; cinematic anim deferred).
- Networked lag compensation / rewind (designed-for, but **not** implemented in v1; see §12).

### Locked Design Decisions (from stakeholder)
| # | Decision |
|---|----------|
| 1 | Weapons are **hitscan**. |
| 2 | Dragged props **do not rotate** (position only). |
| 3 | **One item at a time** — equipping a gun auto-drops a held prop and vice-versa. |
| 4 | Toolchain is **Rojo**; the Git repo is the source of truth (code only). |

---

## 2. Core Architecture Principles

These are **invariants**. Every agent must uphold them.

1. **The client requests and predicts. The server decides and owns the truth.**
   The client may *predict* visuals (recoil, tracer, ammo HUD) for responsiveness, but the server is the sole authority on equip state, ammo, hits, and damage.
2. **The client never sends results, only intents.**
   Never send "I hit player X for 30 damage." Send "I fired from `origin` toward `direction`." The server derives the rest.
3. **All authoritative state lives on the server** (`PlayerHoldState`, `AmmoLedger`, health). Client copies are display-only predictions.
4. **One door per concern.** Cross-boundary communication happens *only* through the RemoteEvents in §6. No agent adds a Remote without updating §6 in the same PR.
5. **Shared truth lives in `shared/`.** Item classification (`ItemRegistry`) and tunables (`Config`) are defined once and consumed by both sides.
6. **Fail safe, fail quiet.** When the server rejects an action, it does nothing harmful and (optionally) notifies the client to roll back its prediction. No errors thrown to exploiters.
7. **Determinism of contracts.** Module public APIs (function names, params, return shapes) are frozen by this document. Internal implementation is each agent's freedom.

---

## 3. System Map

```
┌─────────────────────────── CLIENT (per player) ───────────────────────────┐
│  init.client  → starts all controllers                                     │
│                                                                            │
│  InteractionController  ── raycasts crosshair, asks ItemRegistry,          │
│        │                    routes: Weapon→prompt/E, Prop→drag             │
│        ├── DragController       (AlignPosition hold + fling)               │
│        ├── ViewmodelController  (arms+gun render, sway, bob)               │
│        └── WeaponController      (click→predict→FireRequest)               │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │  RemoteEvents (§6) — the ONLY doors
┌───────────────────────────────────┴────────────────────────────────────────┐
│                              SERVER (referee)                                 │
│  init.server → creates Remotes folder, starts all services                  │
│                                                                              │
│  EquipService   DragService   WeaponService                                  │
│        \            |            /                                            │
│         └──→ PlayerHoldState (single active-hold invariant) ←──┘             │
│                         AmmoLedger (authoritative ammo)                       │
│              CollisionGroups + NetworkOwnership helpers                       │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │
┌───────────────────────────────────┴────────────────────────────────────────┐
│  SHARED (ReplicatedStorage.Shared)                                           │
│  ItemRegistry  (Weapon vs Prop classification + per-item definitions)        │
│  Config        (all tunable numbers in one place)                            │
│  Types         (shared Luau type definitions)                                │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Toolchain & Repository Layout

### Rojo mapping
The repo is code-only. Instances (RemoteEvents) are created at runtime in code. Physical assets (gun models, arms rig) live in a Studio place file referenced by name; they are **not** committed as code.

### Exact file tree (authoritative — do not rename)
```
roblox-combat-system/
├── default.project.json          -- Rojo service mapping
├── .gitignore
├── README.md
├── docs/
│   └── BLUEPRINT.md              -- (this file)
└── src/
    ├── shared/                   -- → ReplicatedStorage.Shared
    │   ├── ItemRegistry.luau
    │   ├── Config.luau
    │   └── Types.luau
    ├── server/                   -- → ServerScriptService.Server
    │   ├── init.server.luau
    │   ├── Remotes.luau          -- builds + returns the Remotes folder
    │   ├── PlayerHoldState.luau
    │   ├── PhysicsAuthority.luau -- collision groups + network ownership helpers
    │   ├── AmmoLedger.luau
    │   ├── EquipService.luau
    │   ├── DragService.luau
    │   └── WeaponService.luau
    └── client/                   -- → StarterPlayerScripts.Client
        ├── init.client.luau
        ├── RemotesClient.luau    -- waits for + returns the Remotes folder
        ├── InteractionController.luau
        ├── DragController.luau
        ├── ViewmodelController.luau
        └── WeaponController.luau
```

### `default.project.json` (target shape — Scaffolding agent owns this)
```jsonc
{
  "name": "roblox-combat-system",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Shared": { "$path": "src/shared" }
    },
    "ServerScriptService": {
      "Server": { "$path": "src/server" }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "Client": { "$path": "src/client" }
      }
    }
  }
}
```

### Module resolution (how agents require each other)
- Shared: `local Config = require(ReplicatedStorage.Shared.Config)`
- Server siblings: `require(script.Parent.AmmoLedger)` (from inside the `Server` folder; `init.server.luau` is the folder script, siblings are its children).
- Client siblings: `require(script.Parent.DragController)`.

---

## 5. Global Conventions

- **Files:** `PascalCase.luau` for modules. `init.server.luau` / `init.client.luau` for folder bootstrap scripts.
- **Modules return a table.** Services/controllers expose `Module.start(deps)` where applicable (see specs). Pure data/util modules just return their table.
- **Functions/methods:** `camelCase`. **Types:** `PascalCase`. **Constants:** `SCREAMING_SNAKE_CASE` (local to a module) or grouped in `Config`.
- **No magic numbers in logic.** Every tunable lives in `Config` (§7.2). If you need a number, add it to `Config` with a comment, don't hardcode it.
- **Strict typing:** every `.luau` file starts with `--!strict`. Use the shared `Types` module for cross-module shapes.
- **RemoteEvent naming:** exact strings from §6. Access via the `Remotes`/`RemotesClient` modules, never `WaitForChild` scattered in random files.
- **Logging:** `warn("[ModuleName] message")` for recoverable issues; never `error()` on player-driven input paths (exploiters could spam). Reserve `error()` for programmer mistakes during init.
- **No `wait()`/`spawn()`** (deprecated). Use `task.wait`, `task.spawn`, `task.defer`.
- **Comments:** explain *why*, not *what*. Mark unresolved contract questions with `-- TODO(contract): ...`.
- **Server never trusts client-sent CFrames/positions for authority** — only as *claims* to be validated.

---

## 6. THE REMOTES CONTRACT

> This is the most important section for parallel work. **These are the only cross-boundary doors.** Names, directions, and payloads are frozen. The server's `Remotes.luau` creates them; the client's `RemotesClient.luau` waits for them. All live in a `ReplicatedStorage.Remotes` folder created at runtime.

All are `RemoteEvent`s unless marked `RemoteFunction`. Prefer `RemoteEvent` (fire-and-forget); we use **no** `RemoteFunction`s in v1 to avoid client-yield exploits — the server pushes results back via paired response events.

| Remote Name | Type | Direction | Payload (in order) | Purpose |
|---|---|---|---|---|
| `EquipRequest` | RemoteEvent | Client→Server | `weaponInstance: Instance` | Player pressed E on a weapon. |
| `EquipResult` | RemoteEvent | Server→Client | `ok: boolean, weaponId: string?, ammo: number?` | Server's verdict; on ok, client shows viewmodel. |
| `UnequipRequest` | RemoteEvent | Client→Server | *(none)* | Player chose to put gun away (e.g. key). |
| `HoldStateChanged` | RemoteEvent | Server→Client | `kind: "Weapon"\|"Prop"\|"None", instance: Instance?` | Server broadcasts authoritative hold changes (incl. auto-drop). |
| `DragStartRequest` | RemoteEvent | Client→Server | `propInstance: Instance, grabOffset: Vector3` | Player mouse-down on a prop. |
| `DragEndRequest` | RemoteEvent | Client→Server | *(none)* | Player released the prop. |
| `DragResult` | RemoteEvent | Server→Client | `ok: boolean, propInstance: Instance?` | Server granted/denied the drag (+ network ownership). |
| `FireRequest` | RemoteEvent | Client→Server | `origin: Vector3, direction: Vector3, clientShotId: number` | Player clicked to shoot. `direction` is unit vector. |
| `FireResult` | RemoteEvent | Server→Client | `clientShotId: number, ok: boolean, ammo: number, hitPosition: Vector3?` | Server's shot verdict + authoritative ammo + confirmed impact. |
| `ShotFired` | RemoteEvent | Server→Clients (broadcast) | `shooter: Player, origin: Vector3, hitPosition: Vector3` | Tells OTHER clients to render tracer/impact. |
| `ReloadRequest` | RemoteEvent | Client→Server | *(none)* | Player requested reload. |
| `ReloadResult` | RemoteEvent | Server→Client | `ok: boolean, ammo: number` | Reload verdict + new ammo. |

### Contract rules every agent must honor
- **Payload order and types are fixed.** Do not add/remove/reorder args. If you genuinely need a new field, you must update this table in the same PR and flag `BREAKING CONTRACT` in the PR title.
- **`clientShotId`** is a monotonically increasing integer the client generates per shot, so the client can reconcile `FireResult` to the correct predicted shot.
- **`weaponId`** is the registry key string (see §7.1 / §10), NOT the Instance.
- **Server is always allowed to send an unsolicited `HoldStateChanged`** (e.g., auto-drop). Clients must react to it as the source of truth, overriding local prediction.
- **Rate limiting:** the server applies per-remote throttling (see `Config.Security`). Clients must not rely on spamming.

---

## 7. Shared Module Specs

### 7.1 `shared/ItemRegistry.luau`
**Owner:** Agent B. **Depends on:** `Types`.

The single source of truth for *what an item is* and *what it allows*. Classification is read from instance **attributes** (see §10), with the registry providing per-weapon definitions keyed by `weaponId`.

**Public API (frozen):**
```lua
ItemRegistry.classify(instance: Instance): "Weapon" | "Prop" | "None"
-- Reads the "ItemType" attribute. Returns "None" if missing/unknown.

ItemRegistry.getWeaponId(instance: Instance): string?
-- Reads the "WeaponId" attribute for weapons; nil otherwise.

ItemRegistry.getWeaponDef(weaponId: string): WeaponDef?
-- Returns the frozen weapon definition table (see Types.WeaponDef).

ItemRegistry.isDraggable(instance: Instance): boolean
-- True only for Props that are not anchored/locked (checks "Draggable" attribute, default true for Props).

ItemRegistry.getAllWeaponDefs(): { [string]: WeaponDef }
```

**`WeaponDef` table content** (see `Types.WeaponDef` in §10) is defined *here* as a frozen table per weapon: `damage`, `maxAmmo`, `fireRateRps`, `range`, `spread`, `reloadTime`, `viewmodelName`, etc.

### 7.2 `shared/Config.luau`
**Owner:** Agent B. **Depends on:** nothing.

ALL tunables in one place. Frozen structure (values are tunable, keys are contract):
```lua
Config = {
  Drag = {
    maxForce = <number>,          -- AlignPosition.MaxForce
    responsiveness = <number>,    -- AlignPosition.Responsiveness
    maxHoldDistance = <number>,   -- studs; auto-release beyond this
    minHoldDistance = <number>,
    holdDistanceDefault = <number>,
    flingVelocityMultiplier = <number>,
    maxPropMass = <number>,       -- props heavier than this can't be dragged
  },
  Viewmodel = {
    swayAmount = <number>, swaySpeed = <number>,
    bobAmount = <number>, bobSpeed = <number>,
    baseOffsetCFrame = <CFrame>,  -- gun position relative to camera
    springDamping = <number>, springFrequency = <number>,
  },
  Weapon = {
    -- per-weapon values live in ItemRegistry WeaponDefs;
    -- this holds global shooting constants:
    serverRayLengthPadding = <number>,
    maxAimDeviationDegrees = <number>, -- plausibility check threshold
  },
  Security = {
    fireRequestCooldownMs = <number>,    -- hard floor regardless of weapon
    dragRequestCooldownMs = <number>,
    equipRequestCooldownMs = <number>,
    maxEquipDistance = <number>,         -- studs from player to weapon
    maxDragStartDistance = <number>,     -- studs from player to prop
  },
  CollisionGroups = {
    heldObjects = "HeldObjects",
    players = "Players",
    default = "Default",
  },
}
```

### 7.3 `shared/Types.luau`
**Owner:** Agent B. Exports Luau types used across modules (see §10 for the canonical shapes). Other modules do `local Types = require(...Types)` and reference `Types.WeaponDef`, `Types.HoldState`, etc.

---

## 8. Server Module Specs

### 8.0 `server/init.server.luau`
**Owner:** Agent C (Foundation).
- Requires `Remotes` (creates the folder), `PhysicsAuthority` (registers collision groups), then `.start()`s each service in order: `AmmoLedger`, `PlayerHoldState`, `EquipService`, `DragService`, `WeaponService`.
- Wires `Players.PlayerRemoving` cleanup across services.

### 8.1 `server/Remotes.luau`
**Owner:** Agent C.
- Creates a `ReplicatedStorage.Remotes` Folder and all RemoteEvents from §6 exactly once.
- Returns a typed table: `Remotes.EquipRequest`, etc. **Never** create remotes elsewhere.

### 8.2 `server/PhysicsAuthority.luau`
**Owner:** Agent C.
**Public API:**
```lua
PhysicsAuthority.registerCollisionGroups()  -- creates HeldObjects/Players groups, sets HeldObjects×Players = no collide
PhysicsAuthority.setHeld(part: BasePart)     -- put part in HeldObjects group
PhysicsAuthority.setReleased(part: BasePart) -- restore to Default group
PhysicsAuthority.giveOwnership(part: BasePart, player: Player)
PhysicsAuthority.returnOwnership(part: BasePart) -- SetNetworkOwner(nil)
PhysicsAuthority.assignCharacterToPlayersGroup(character: Model)
```
Also connects `CharacterAdded` to put player parts in the `Players` group.

### 8.3 `server/PlayerHoldState.luau`
**Owner:** Agent D. **The single-active-hold invariant lives here.**
**State:** `holds: { [Player]: { kind: "Weapon"|"Prop"|"None", instance: Instance? } }`
**Public API:**
```lua
PlayerHoldState.get(player: Player): HoldState
PlayerHoldState.setWeapon(player: Player, weapon: Instance, weaponId: string)
PlayerHoldState.setProp(player: Player, prop: Instance)
PlayerHoldState.clear(player: Player): HoldState  -- returns the PREVIOUS hold so callers can run drop/unequip side effects
PlayerHoldState.isHolding(player: Player): boolean
```
**Rule:** `setWeapon`/`setProp` MUST internally call `clear` first and return what was cleared, so callers (EquipService/DragService) can run the appropriate teardown (release constraint / hide viewmodel). Always fire `HoldStateChanged` after a change.
> Because Equip and Drag both mutate this, **only PlayerHoldState mutates `holds`**; EquipService/DragService call its API. This avoids two agents writing the same state two ways.

### 8.4 `server/AmmoLedger.luau`
**Owner:** Agent E. **Authoritative ammo — the anti-cheat core.**
**State:** `ammo: { [Player]: { [weaponId: string]: number } }`
**Public API:**
```lua
AmmoLedger.onEquip(player: Player, weaponId: string)  -- initializes to maxAmmo if first time
AmmoLedger.get(player: Player, weaponId: string): number
AmmoLedger.canFire(player: Player, weaponId: string): boolean
AmmoLedger.consumeRound(player: Player, weaponId: string): boolean -- decrement if >0, else false
AmmoLedger.reload(player: Player, weaponId: string): number -- refill to maxAmmo, return new count
AmmoLedger.clearPlayer(player: Player)
```
**Rule:** This is the **only** module allowed to mutate ammo. WeaponService asks; it never writes ammo itself.

### 8.5 `server/EquipService.luau`
**Owner:** Agent F. **Depends on:** Remotes, PlayerHoldState, AmmoLedger, PhysicsAuthority, ItemRegistry, Config, DragService (for auto-drop teardown).
**Handles:** `EquipRequest`, `UnequipRequest`.
**Validation pipeline for `EquipRequest(weapon)`:**
1. Rate-limit per `Config.Security.equipRequestCooldownMs`.
2. `ItemRegistry.classify(weapon) == "Weapon"` else reject.
3. `weaponId = ItemRegistry.getWeaponId(weapon)`; def exists.
4. Distance: player root within `Config.Security.maxEquipDistance` of weapon.
5. Availability: weapon not already equipped by someone else.
6. `PlayerHoldState.setWeapon(...)` (auto-clears any prop drag via returned previous hold → calls `DragService.forceRelease`).
7. `AmmoLedger.onEquip(player, weaponId)`.
8. Server attaches weapon to character (authoritative weld/parent).
9. Fire `EquipResult(true, weaponId, ammo)`.
Reject path: `EquipResult(false)` and do nothing else.

### 8.6 `server/DragService.luau`
**Owner:** Agent G. **Depends on:** Remotes, PlayerHoldState, PhysicsAuthority, ItemRegistry, Config, EquipService (for auto-unequip teardown).
**Handles:** `DragStartRequest`, `DragEndRequest`.
**`DragStartRequest(prop, grabOffset)` pipeline:**
1. Rate-limit per `Config.Security.dragRequestCooldownMs`.
2. `ItemRegistry.classify(prop) == "Prop"` and `isDraggable(prop)`.
3. Mass ≤ `Config.Drag.maxPropMass`; not anchored.
4. Distance ≤ `Config.Security.maxDragStartDistance`.
5. `PlayerHoldState.setProp(...)` (auto-unequips gun via previous hold → `EquipService.forceUnequip`).
6. `PhysicsAuthority.setHeld(prop)` + `giveOwnership(prop, player)`.
7. Fire `DragResult(true, prop)`.
**`DragEndRequest`:** `PhysicsAuthority.setReleased` + `returnOwnership`; `PlayerHoldState.clear`. (The actual `AlignPosition` lives **client-side**, owned by the client that has network ownership — see §9.3. Server only governs ownership/collision/state.)
**Public API for cross-service teardown:** `DragService.forceRelease(player)` (used by EquipService).

### 8.7 `server/WeaponService.luau`
**Owner:** Agent H. **Depends on:** Remotes, PlayerHoldState, AmmoLedger, ItemRegistry, Config.
**Handles:** `FireRequest`, `ReloadRequest`.
**`FireRequest(origin, direction, clientShotId)` validation pipeline (hitscan):**
1. Rate-limit hard floor `Config.Security.fireRequestCooldownMs`.
2. `hold = PlayerHoldState.get(player)`; must be a Weapon; resolve `weaponId`, `def`.
3. Per-weapon fire-rate: time since last shot ≥ `1/def.fireRateRps` (server-tracked timestamp).
4. `AmmoLedger.canFire` then `consumeRound`; if false → `FireResult(id, false, 0)`.
5. **Plausibility:** angle between `direction` and player's actual look vector ≤ `Config.Weapon.maxAimDeviationDegrees`; `origin` near player's camera/head position.
6. **Authoritative raycast** from a server-trusted origin (player head) along `direction`, length `def.range`, with a raycast filter that ignores the shooter's own character. This naturally enforces **line-of-sight / no shooting through walls** (first hit wins; a wall blocks).
7. If hit a damageable humanoid: apply `def.damage` (server-side). 
8. Fire `FireResult(clientShotId, true, newAmmo, hitPosition)` to shooter; broadcast `ShotFired(shooter, origin, hitPosition)` to others.
**`ReloadRequest`:** validate weapon held → `AmmoLedger.reload` after `def.reloadTime` → `ReloadResult`.

---

## 9. Client Module Specs

### 9.0 `client/init.client.luau`
**Owner:** Agent C. Requires `RemotesClient`, then `.start()`s controllers: `ViewmodelController`, `InteractionController`, `DragController`, `WeaponController`.

### 9.1 `client/RemotesClient.luau`
**Owner:** Agent C. `WaitForChild("Remotes")` then returns typed handles. Single access point.

### 9.2 `client/InteractionController.luau`
**Owner:** Agent I. **Depends on:** ItemRegistry, RemotesClient, DragController, Config.
- Each frame (or on a throttle), raycast from camera center to find the item under the crosshair.
- `classify` the hit:
  - **Weapon** → enable an "E to Equip" affordance (use a `ProximityPrompt` on the weapon, or a custom prompt). On E (prompt triggered) → fire `EquipRequest(weapon)`.
  - **Prop** → no E. On mouse-down over a draggable prop → call `DragController.beginDrag(prop, hit)`.
  - **None** → clear prompts.
- Listens to `HoldStateChanged` to update crosshair/HUD state.
> InteractionController decides intent; it does NOT itself create constraints (that's DragController) or render arms (ViewmodelController).

### 9.3 `client/DragController.luau`
**Owner:** Agent J. **Depends on:** RemotesClient, Config.
- `beginDrag(prop, raycastResult)`: compute `grabOffset`, fire `DragStartRequest`. On `DragResult(true)`, create a client-side `Attachment` + `AlignPosition` (no `AlignOrientation` — rotation disabled per decision #2) once the client owns the part (network ownership granted server-side).
- Each `RenderStepped` while dragging: move the target attachment to a point under the mouse, clamped between `Config.Drag.minHoldDistance` and `maxHoldDistance` in front of the camera.
- Auto-release if the prop exceeds `Config.Drag.maxHoldDistance` from the player (anti-float-away).
- `endDrag()`: destroy constraint/attachments, fire `DragEndRequest`. **Fling** is emergent — releasing while moving keeps momentum; optionally apply `flingVelocityMultiplier`.
- Public: `beginDrag`, `endDrag`, `isDragging()`. Reacts to `HoldStateChanged(kind="None")` to force-release if the server dropped it.

### 9.4 `client/ViewmodelController.luau`
**Owner:** Agent K. **Depends on:** Config, RemotesClient, ItemRegistry.
- State machine: `Empty ↔ Weapon`. On `EquipResult(true, weaponId)` / `HoldStateChanged(kind="Weapon")`, build/show the arms+gun viewmodel for `def.viewmodelName`. On `None`, hide it.
- Each `RenderStepped`: base CFrame = camera CFrame × `Config.Viewmodel.baseOffsetCFrame`, then layer:
  - **Look-sway** from camera rotation delta (spring-smoothed).
  - **Walk-bob** sine wave scaled by humanoid speed.
- Purely cosmetic; never authoritative for aim. Exposes muzzle attachment so WeaponController can spawn tracers/flash.
- Public: `start`, `getMuzzlePosition()`, `playFireKick()`.

### 9.5 `client/WeaponController.luau`
**Owner:** Agent L. **Depends on:** RemotesClient, ViewmodelController, ItemRegistry, Config.
- Tracks local predicted ammo + equip (synced from `EquipResult`/`FireResult`/`HoldStateChanged`).
- On mouse click (only if a weapon is held, not on cooldown, predicted ammo > 0):
  - Predict instantly: `ViewmodelController.playFireKick()`, muzzle flash, sound, local tracer; decrement predicted ammo; raycast from camera for local impact feel.
  - Generate `clientShotId`, fire `FireRequest(origin, direction, clientShotId)`.
- On `FireResult`: set predicted ammo to authoritative `ammo`; if `ok=false`, roll back the predicted shot visuals/ammo.
- On `ShotFired` (from others): render their tracer/impact.
- Handles `ReloadRequest`/`ReloadResult`, updates ammo HUD.

---

## 10. Data Schemas

### Item attributes (set on instances in Studio; read by ItemRegistry)
| Attribute | Type | On | Meaning |
|---|---|---|---|
| `ItemType` | string | every interactable | `"Weapon"` or `"Prop"`. |
| `WeaponId` | string | weapons | key into `ItemRegistry` weapon defs, e.g. `"pistol_9mm"`. |
| `Draggable` | bool | props (optional) | default `true`; `false` locks a prop. |

### `Types.WeaponDef` (frozen shape)
```lua
export type WeaponDef = {
  weaponId: string,
  displayName: string,
  damage: number,
  maxAmmo: number,
  fireRateRps: number,   -- rounds per second
  range: number,         -- studs
  spread: number,        -- degrees (0 = perfectly accurate)
  reloadTime: number,    -- seconds
  viewmodelName: string, -- asset name for ViewmodelController
}
```

### `Types.HoldState`
```lua
export type HoldState = {
  kind: "Weapon" | "Prop" | "None",
  instance: Instance?,
  weaponId: string?, -- present iff kind == "Weapon"
}
```

---

## 11. End-to-End Sequence Flows

### A) Equip a weapon (E)
```
Player aims at weapon → InteractionController shows "E" prompt
Player presses E → FireRequest? NO → EquipRequest(weapon) → Server
Server EquipService: validate(type, distance, availability)
  → PlayerHoldState.setWeapon (auto-drops any prop via DragService.forceRelease)
  → AmmoLedger.onEquip → attach weapon
  → EquipResult(true, weaponId, ammo) to shooter
  → HoldStateChanged("Weapon", weapon) [broadcast/relevant]
Client: ViewmodelController shows arms+gun; WeaponController arms itself
```

### B) Grab & fling a prop (mouse)
```
Player mouse-down on prop → InteractionController → DragController.beginDrag
  → DragStartRequest(prop, grabOffset) → Server
Server DragService: validate(type, mass, distance)
  → PlayerHoldState.setProp (auto-unequips gun via EquipService.forceUnequip)
  → PhysicsAuthority.setHeld + giveOwnership(prop, player)
  → DragResult(true, prop)
Client: create AlignPosition; each frame move target under mouse (clamped)
Player mouse-up → DragController.endDrag → DragEndRequest
Server: setReleased + returnOwnership + PlayerHoldState.clear
(Momentum at release = fling)
```

### C) Fire (hitscan)
```
Player clicks (weapon held, predicted ammo>0, off cooldown)
Client WeaponController: predict (kick/flash/tracer/sound, ammo--)
  → FireRequest(origin, direction, clientShotId) → Server
Server WeaponService: rate-limit → hold==Weapon → fire-rate → AmmoLedger.consumeRound
  → plausibility(angle/origin) → authoritative raycast (LoS/walls/range)
  → apply damage if humanoid hit
  → FireResult(clientShotId, true, newAmmo, hitPos) to shooter
  → ShotFired(shooter, origin, hitPos) to others
Client: reconcile ammo to authoritative; others render tracer
```

---

## 12. Anti-Cheat Checklist

Every item must be true in the final system:
- [ ] Client never sends damage, victim, or "hit" booleans — only `origin`, `direction`, `clientShotId`.
- [ ] Ammo decrement happens **only** in `AmmoLedger` on the server. (Stops infinite ammo.)
- [ ] Server enforces per-weapon fire rate via server timestamps. (Stops rapid-fire macros.)
- [ ] Server performs its **own** raycast from a trusted origin. (Stops shoot-through-walls & teleport-aim.)
- [ ] Server verifies the player actually holds that weapon via `PlayerHoldState`. (Stops phantom-weapon fire.)
- [ ] Distance checks on equip and drag-start. (Stops remote grabbing.)
- [ ] Network ownership of props returns to server on release. (Stops loose-part exploits.)
- [ ] Per-remote rate limiting on every Client→Server remote. (Stops spam.)
- [ ] Plausibility check: claimed `direction` within `maxAimDeviationDegrees` of real look vector.
- [ ] `HoldStateChanged` from server always overrides client prediction.
- [ ] **(v2, designed-for not built):** lag compensation / hit rewind — leave a `-- TODO(v2: lagcomp)` anchor in WeaponService.

---

## 13. Work Packages for 10 Agents

Each package lists: **owns** (files it may write), **must honor** (frozen contracts), **deps** (what must exist first), **acceptance**. An agent writes ONLY its owned files. Shared contracts come from this doc, so packages can start in parallel against the documented interfaces (stubs allowed where a dep isn't merged yet).

> Mapping note: there are 12 source areas; we group into **10 agents** by merging two small foundation pieces. Agent C carries the foundation (both bootstraps + Remotes + PhysicsAuthority) since everything depends on it and it should land first.

| Agent | Package | Owns (files) | Deps | Must honor |
|---|---|---|---|---|
| **A — Scaffolding** | Rojo project + repo hygiene | `default.project.json`, `.gitignore`, `README.md` updates, empty `src/**` tree + bootstrap stubs | none | §4 tree exactly |
| **B — Shared Core** | Registry/Config/Types | `src/shared/ItemRegistry.luau`, `Config.luau`, `Types.luau` | A | §7, §10 APIs frozen |
| **C — Foundation** | Bootstraps + Remotes + Physics authority | `src/server/init.server.luau`, `Remotes.luau`, `PhysicsAuthority.luau`, `src/client/init.client.luau`, `RemotesClient.luau` | A | §6 remote names, §8.1–8.2 APIs |
| **D — Hold State** | Single-hold invariant | `src/server/PlayerHoldState.luau` | C, B | §8.3 API + auto-clear rule |
| **E — Ammo Ledger** | Authoritative ammo | `src/server/AmmoLedger.luau` | B | §8.4 (only mutator of ammo) |
| **F — Equip (server)** | Equip pipeline | `src/server/EquipService.luau` | C, D, E, B | §8.5, §6 EquipRequest/Result, must call DragService.forceRelease |
| **G — Drag (server)** | Drag authority | `src/server/DragService.luau` | C, D, B | §8.6, §6 Drag remotes, must call EquipService.forceUnequip |
| **H — Weapon (server)** | Shooting validation | `src/server/WeaponService.luau` | C, D, E, B | §8.7, §6 Fire/Reload, §12 checklist |
| **I — Interaction (client)** | Crosshair routing + E vs mouse | `src/client/InteractionController.luau` | C, B | §9.2, ItemRegistry.classify routing |
| **J — Drag (client)** | AlignPosition hold + fling | `src/client/DragController.luau` | C, B | §9.3, no AlignOrientation |
| **K — Viewmodel (client)** | Arms+gun render + sway/bob | `src/client/ViewmodelController.luau` | C, B | §9.4, cosmetic-only |
| **L — Weapon (client)** | Click→predict→fire | `src/client/WeaponController.luau` | C, B, K | §9.5, prediction+reconcile |

> That is 12 lettered roles. To run with **exactly 10 agents**, combine as follows (recommended balanced split):
> - **Agent 1 = A + C** (all scaffolding & foundation — lands first, unblocks everyone).
> - **Agent 2 = B** (shared core — lands first alongside foundation).
> - **Agent 3 = D**, **Agent 4 = E**, **Agent 5 = F**, **Agent 6 = G**, **Agent 7 = H** (server services).
> - **Agent 8 = I + J** (client interaction + client drag — tightly coupled), **Agent 9 = K**, **Agent 10 = L**.
>
> Alternatively keep 12 roles and assign 2 agents two packages each. Either way, **no two agents write the same file.**

### Cross-service teardown contract (prevents the #1 parallel-work hazard)
Equip and Drag both need to undo each other (one-item rule). To avoid circular ownership confusion:
- `PlayerHoldState.setWeapon/setProp` returns the **previous** hold.
- The *calling* service inspects it and calls the counterpart's public teardown: `DragService.forceRelease(player)` or `EquipService.forceUnequip(player)`.
- These two public functions (`forceRelease`, `forceUnequip`) are part of the frozen API. Agents F and G must each expose theirs even before the other is merged (stub acceptable: warn + no-op until implemented).

---

## 14. Parallel-Work & Merge Strategy

1. **Land foundation first.** Agents 1 (A+C) and 2 (B) merge before others integrate. Until then, all other agents code against the *documented* interfaces and may add a local stub `require` shim.
2. **One file = one owner.** The §13 table is the ownership map. If you feel you must edit a file you don't own, instead post the needed change as a PR comment and `-- TODO(contract)`; do not silently edit another agent's file.
3. **Branch naming:** `cursor/<area>-e7b7` (e.g. `cursor/server-weaponservice-e7b7`). One PR per package.
4. **Contracts are append-only during the sprint.** Changing a §6 remote or a frozen API requires a `BREAKING CONTRACT` PR that updates this doc; reviewers must re-sync dependents.
5. **Stubs over blocking.** If your dep isn't merged, depend on the documented signature and stub it. Real wiring happens once both land — keep the seam at the documented API so integration is mechanical.
6. **Integration owner:** Agent 1 (foundation) also owns final `init` wiring order and resolves merge order conflicts in the bootstrap files.
7. **Definition of Done per PR:** file(s) compile under `--!strict`, honor the contract signatures verbatim, include a short `-- Module:` header comment describing responsibility, and pass the relevant §15 tests.

---

## 15. Testing Plan

Test in Studio via Rojo sync. Each package has a minimum bar:

- **Shared (B):** unit-style asserts in a temporary test script — `classify` returns correct types for tagged instances; `getWeaponDef` returns frozen defs; `Config` keys all present.
- **Foundation (C):** Remotes folder appears with all §6 events; collision groups exist; `Players×HeldObjects` is non-colliding.
- **HoldState (D):** setting weapon then prop clears the weapon and returns the prior hold; `HoldStateChanged` fires each transition.
- **AmmoLedger (E):** `consumeRound` decrements to 0 then returns false; `reload` refills; isolated per player+weapon.
- **Equip (F):** E on a weapon shows viewmodel; E while dragging a prop drops the prop first; far-away weapon rejected.
- **Drag (G/J):** prop follows mouse smoothly; never enters the player (collision group); auto-releases past max distance; release → fling; heavy/anchored props rejected.
- **Weapon (H/L):** firing decrements server ammo; spamming faster than RoF rejected; shooting a target behind a wall deals no damage; predicted ammo reconciles to server value; `clientShotId` reconciliation correct.
- **Viewmodel (K):** arms appear in first person, sway on look, bob on walk, hidden when empty; muzzle position exposed.
- **Anti-cheat (cross-cutting):** simulate forged `FireRequest` with bad direction → rejected; forged equip at distance → rejected; rapid `FireRequest` spam → throttled & out of ammo.

A simple manual **playtest script** (2 players: one shoots, one hides behind a wall) validates the headline anti-cheat goals end to end.

---

## 16. Glossary

- **Hitscan:** instantaneous ray-based hit detection (no projectile travel time).
- **Viewmodel:** camera-attached cosmetic arms+gun rig shown only to the local player.
- **Network ownership:** which machine simulates a part's physics; granted to the dragger for smoothness, returned to server on release.
- **AlignPosition:** Roblox constraint that pulls a part toward a target attachment (used for dragging; no rotation constraint in v1).
- **PlayerHoldState:** the server's single source of truth for what each player currently holds (one item max).
- **AmmoLedger:** the server's authoritative ammo store; the only ammo mutator.
- **Prediction / reconciliation:** client shows the action instantly, then corrects to the server's authoritative result.
- **Prop:** a draggable physics object (mouse only, no E).
- **Weapon:** an equippable gun (E to equip, hitscan to fire).

---

*End of blueprint. Build in dependency order; honor the contracts; keep authority on the server.*
