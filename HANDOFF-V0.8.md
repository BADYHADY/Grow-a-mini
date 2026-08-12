# HANDOFF — MINI ME FIGHTERS, end of V0.8

Written 2026-08-12. Supersedes `HANDOFF-V0.6.md` on everything it covers.

Read this before `PROMT.txt` / `Handoff Promt.txt`. Those are older and describe
systems that have since been replaced — where they disagree with this file, this
file is right about the code and the canon (`PROMT.txt` §1–§56) is right about
the product.

---

## 0. THE DIVISION OF LABOUR

**Elias builds the world. Claude writes the code.**

This is the working agreement from here on, and the code is already shaped for
it. Nothing about the layout is hardcoded: every placement is measured off the
map at runtime. Move a platform in Studio, resize it, rotate it — the game
follows without a code change.

### What Elias owns

Everything under `ServerStorage.Assets`:

| Asset | What it is | Rules the code depends on |
|---|---|---|
| `BaseMap` | The level: `DojoSpace`, `Bridge`, `ArenaPlate` | Those three names must exist and be `BasePart`s. They should form a walkable chain. Tops should be flush. |
| `Dojo` | The training hut | Must contain `dojoFloor_Node` — the code stands the Mini and the bag on it. It is open on ONE face; the code rotates it 180° so the opening points down the map. |
| `Punchingbag` | The bag | Must contain a part whose name contains `bagbody`, and a `Bag_modle` model. |
| `Arena` | The Colyseum | Anything. Scaled and measured automatically. |

Also Elias's: lighting, sky, water, terrain, colours, materials, decoration.

### What Claude owns

Everything under `src/` — services, controllers, config. And the contract above:
if you rename `DojoSpace`, tell Claude and it becomes a one-line change.

### The one thing to be careful about

The map is **cloned per player** onto a grid. `MiniBaseService.CONFIG.SlotSpacing`
(36) and `RowSpacing` (70) must stay larger than the map's footprint or bases
overlap. Current map is 26 wide × 50 deep, so there is room, but if you make the
map much bigger, say so.

---

## 1. WHAT THE GAME IS

From the canon, unchanged: **you grow a miniature version of your own Roblox
avatar into a fighter.** The Mini is not a pet. It is you.

The loop Elias stated most recently, and the one to protect:

```
spawn (Mini already strong enough to fight)
  -> SEND TO TOWER
  -> fights, wins some floors, gets KO'd
  -> walks home to the dojo
  -> trains on the bag, heals, gains Power
  -> TOWER again, further this time
  -> coins -> upgrade -> TOWER -> upgrade -> unstoppable
```

Two buttons: **FOLLOW ME** and **SEND TO TOWER**. That is the whole interface.

---

## 2. CURRENT STATE — WHAT WORKS

Verified by measurement in Studio this session unless marked otherwise.

- **Mini is the player's avatar**, R15, built from `HumanoidDescription`, scaled
  to 0.35. Appearance loads async behind a grey placeholder.
- **Movement is the Roblox engine.** The Mini is a physical `Humanoid`, walked by
  the SERVER with `Humanoid:MoveTo` along a `PathfindingService` route. The
  hand-written client locomotion (≈500 lines) is deleted.
- **Walk animation plays** — stock R15 walk, speed scaled to the Mini's stride.
- **Punching works** — not an animation file; the client poses the joints from a
  shared punch clock. Arm cycles on the beat, opponent's health drops.
- **The full loop closes**: train → Ready → tower → floors → KO → walk home →
  train → Ready. No teleports.
- **Anti-farm holds**: a full-health Mini earns nothing, so toggling
  FOLLOW/TRAIN is not free progression.
- **World-space signs work** (Elias confirmed): `FLOOR N` / `@owner` / `$reward`
  over the pit, `PUNCHING BAG NV.x` / `x1.00 · $25` over the bag, and the Mini's
  stat plate `NAME LV.n ⚔power ❤health` with an XP bar.
- **Server owns all state**: Power, Health, XP, Coins, floor, rewards, upgrades.

---

## 3. OPEN BUGS — START HERE

### 3.1 BLOCKER: the arena plate has no collision where the Mini fights

**The Mini walks to the Colyseum, falls through the arena plate into the water,
and gets stuck there for the rest of the session.**

Evidence gathered at the very end of the session, all from the running game:

```
ArenaPlate  CFrame = (-72, 0, 119)  Size = (26, 1, 26)   -- so z spans 106..132
            CanQuery=true CanCollide=true Anchored=true

raycast down, Include filter = {ArenaPlate} only, from y=20 at x=-72:
    z=107 -> MISS
    z=112 -> MISS
    z=119 -> HIT y=0.50     <- the exact centre, and only there
    z=128 -> MISS

arena parts with CanCollide: 0        <- deliberate, see below
ArenaFloor exists: false              <- SHOULD exist
ArenaRamp  exists: false              <- SHOULD exist
```

Two separate faults here, and the second is the likely cause of the first being
fatal:

**(a) `ArenaFloor` and `ArenaRamp` are missing.** `buildArena` in
`MiniBaseService` is supposed to create an invisible sand disc and an entrance
ramp, because the Colyseum mesh is one solid piece with no doorway and is
therefore set `CanCollide = false` and treated as scenery. A later edit
(V0.8F, which added `FighterMark`) used a text anchor that overlapped the block
added in V0.8E and **silently deleted the sand and ramp code**. Check
`buildArena` — the `arena:SetAttribute("FloorRadius", radius)` line should be
followed by the collide-off loop, the `ArenaFloor` cylinder and the `ArenaRamp`
wedge. Re-add them. With the arena mesh non-collidable and no sand disc, there
is nothing at all to stand on inside the pit.

**(b) The plate ray misses everywhere except dead centre.** This one is not
explained. A 26×1×26 anchored `Part` with `CanQuery = true` should be hit by a
downward ray anywhere inside its footprint. It is not. Worth re-testing from a
clean Studio restart before assuming it is real — it may be an artifact of the
plate having been resized in Edit mode while a clone of it was live.

Note that `FloorY` now measures as **0.50**, identical to the plate top, because
the arena was shrunk and sunk. So `rise = 0` and the ramp is degenerate — when
re-adding the ramp, guard for `rise <= 0` and skip it.

### 3.2 The Mini takes shortcuts off the map

Partly addressed, unverified. A `PathfindingModifier` labelled `OffMap` was added
to `Workspace.Baseplate`, and the agent in `MiniService` prices it at
`math.huge`. This should keep routes on the platforms. It was never tested,
because 3.1 killed the run first.

### 3.3 Studio screen capture times out through MCP

`mcp__Roblox_Studio__screen_capture` has never once succeeded this project, in
either Studio instance, foregrounded or not. **Do not rely on it.** The way that
does work: ask Elias to record, then pull frames with ffmpeg (see §6).

---

## 4. ARCHITECTURE — THE PARTS THAT MUST NOT BE CASUALLY REWRITTEN

### The punch clock

Server and client both count punches as `floor((serverTime - epoch) * rate)` off
`Shared/Util/PunchClock`. No remote fires per punch. The client animates punch N,
`TrainingService` pays for punch N, `TowerService` resolves damage for punch N.
This is why 24 Minis cost nothing on the wire and why a hacked client cannot earn
a single extra point of Power. **Do not replace this without a very strong
reason.**

### Server-driven movement

- The Mini's parts are unanchored and **the server claims physics ownership**
  with `SetNetworkOwner(nil)` (`MiniService.claimPhysics`). Without this, Roblox
  hands the body to the nearest player's client, that client simulates nothing,
  and the server's movement is overwritten every frame — the Mini simply will
  not move. This cost hours; do not undo it.
- `Shared/Util/PathAgent` walks a Humanoid along a computed path following
  Roblox's documented pattern: `CreatePath` with agent parameters sized for a
  two-stud fighter, `ComputeAsync`, walk the waypoints, listen to `Blocked`,
  recompute. One agent per Mini. Calling `walkTo` again cancels the walk in
  progress — that is what makes a button press instant.
- Orders for a place the Mini is **already walking to** must not restart the
  walk. `MiniService.applyAction` checks `walkDestinations` for this. Without it
  the tower re-issues `Fighting` every floor and the Mini fights the whole run
  standing in its own dojo.
- Anything that must happen **on arrival** waits on `MiniService.isWalking`, not
  a timer. A fixed delay used to order the Mini home while it was still walking
  home, so it turned round and started again.

### Client animation speed

The client reads walk speed from the root's **replicated
`AssemblyLinearVelocity`**. Two things that do NOT work, both measured:
- Deriving speed from frame-to-frame position deltas. The server owns the body,
  so position arrives ~20 times a second while the loop runs every frame; most
  frames read zero and the animation never plays.
- `Humanoid.Running`. It does not fire on this client at all — that signal
  belongs to whoever simulates the Humanoid, and that is the server.

### The rig has no Motor6D

It is a modern **`AnimationConstraint`** rig (15 of them) plus
`BallSocketConstraint`s, from Roblox's Avatar Joint Upgrade. `IsKinematic` is
true, so animations drive it exactly like Motor6D would. Any code that touches
joints must accept both classes — `MiniController` already does.

### Collision groups

Minis are in group `Minis`, player characters in `Players`, and the two do not
collide, nor do Minis with each other. Set up in `MiniAvatarService.Init`. This
is what stops a player barging their own fighter off the bridge.

---

## 5. THE FILES

```
src/server/Services/
  MiniBaseService.luau   Builds the world per player from BaseMap + assets.
                         Measures everything. Owns the signs. START HERE for 3.1.
  MiniService.luau       Mini lifecycle, action state, routes, walking, wander.
  MiniAvatarService.luau Builds the R15 Mini, physics setup, collision groups.
  TrainingService.luau   What a punch is worth. Anti-farm. Bag wear. Bag sign.
  TowerService.luau      Floors, opponents, rewards, the arena sign.
  MiniCommandService.luau  The two buttons.
  DataService.luau       ProfileStore. Mock store in Studio.
src/client/Controllers/
  MiniController.luau    Punch pose, pose mirroring, bag swing, walk animation.
                         NO LONGER moves the Mini.
  MiniStatsController.luau  The stat plate over the Mini's head.
  HudController / CommandController / MiniEffectsController / DebugController
src/shared/
  Config/MiniConfig.luau    Almost every tunable number, heavily commented.
  Config/UpgradeConfig.luau Upgrade costs and bonuses.
  Util/PathAgent.luau       Documented-pattern pathfinding for one Humanoid.
  Util/PunchClock.luau      The shared clock. Sacred.
```

---

## 6. HOW TO ACTUALLY SEE THE GAME

Screen capture through MCP does not work. This does:

1. Elias records gameplay (any format; `.mkv` is fine).
2. `ffmpeg` is installed at
   `C:\Users\elias\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*\bin`
   — add it to `PATH` in the shell before use.
3. Extract frames, cropping to the Studio viewport if it is a windowed recording:
   ```bash
   ffmpeg -i "clip.mkv" -vf "crop=988:566:296:198,fps=0.45,scale=1000:-2" -q:v 3 out/v_%03d.jpg
   ```
   (crop is `W:H:X:Y` against a 1920×1080 source; adjust to the window.)
4. `Read` the frames.

The `watch` plugin is installed but its frame extraction fails on ffmpeg 9.0
(`Unrecognized option 'vsync'`). Extract manually as above.

Doing this once at the end of V0.8 found more real problems in three frames than
a dozen rounds of measuring attributes had. **Look at the game early.**

---

## 7. WHAT V0.9 SHOULD BE

In order.

1. **Fix 3.1.** The loop is broken until the Mini can stand in the arena.
2. **Verify 3.2** — that the Mini stays on the platforms.
3. **Make the world not grey.** Grass and water are in as of this session but
   unverified on screen. This is mostly Elias's half.
4. Then, and only then, the canon's V0.9A: the Fusion / Evolution foundation.

Do not add meta systems while the loop has a hole in it.

---

## 8. HOW TO WORK ON THIS

- Speak Swedish to Elias. Code, comments, variables and in-game text in English.
- Smallest safe change. Test the target feature, then regression-test the whole
  loop: spawn → train → Ready → tower → floors → KO → walk home → train.
- **Measure, do not assume.** Every real bug this session was found by probing
  the running game with `execute_luau`, and several were the opposite of what the
  code looked like it did.
- Beware Python text-replacement edits against this codebase: the indentation is
  inconsistent (some files have no leading tabs), and one overlapping anchor
  silently deleted a working block — that is bug 3.1(a). Prefer the `Edit` tool,
  and re-grep after any scripted edit.
- Commit per coherent slice with a message that says what was wrong and how it
  was proven.
