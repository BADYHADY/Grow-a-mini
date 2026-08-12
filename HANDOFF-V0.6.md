# MASTER HANDOFF — GROW A MINI / MINI ME FIGHTER
## Project state: 12 August 2026 (V0.6)

You are taking over as lead developer, game designer and technical architect for a
Roblox game. **Read this entire handoff before writing or changing any code.**

Two older documents sit in the repo root and are still authoritative on *vision*:

- `PROMT.txt` — the original master brief (product thesis, loops, monetisation,
  KPI framework, phase plan). Read it for WHY.
- `Handoff Promt.txt` — the previous handoff (August 11). Read it for the history
  of decisions, especially §16–§20 on the R15 Mini and the appearance pipeline.

**This document supersedes `Handoff Promt.txt` on anything about current state.**

---

## 0. THE ONE-SENTENCE VISION

> You grow a miniature version of your own Roblox avatar into an insane fighter.

Inspired by the *structure* of Grow a Chicken Fighter — never its IP, assets or
code. The differentiator is player identity: not "look at my rare pet" but
**"look what I turned myself into."**

The game is a **semi-automatic simulator/tycoon**, not an action game. The player
is the coach: they choose what the Mini does. The Mini executes automatically.
If you are ever unsure whether to make something more manual or more automatic,
**choose automatic with strategic player decisions.**

---

## 1. WHAT ACTUALLY WORKS RIGHT NOW

The core loop is closed and verified in Studio playtests end to end:

```
Mini spawns beside player (mirrors the owner's real R15 pose)
   ↓  2s
walks to the dojo, punches the bag
   ↓  every punch: +Power, +Health, +XP, +1 coin
XP bar fills → LEVEL UP → +health ceiling, +health, +Power, Mini GROWS
   ↓  health full
stops punching, wanders the dojo floor   ← this idling IS the "ready" signal
   ↓  player presses SEND TO TOWER
runs to the pit, fights floor 1, 2, 3…   ← coins per floor, health drains
   ↓  health hits 0
knocked out, walks home by itself
   ↓
back on the bag, health refills, loop repeats
   ↓
coins → UPGRADE PUNCHING BAG → every punch worth more
```

Measured in a real run: LV.2 with 420 HP, sent out, cleared floors 1–5, coins
13 → 64, died, walked home, resumed training. The bag upgrade costs $25, so one
run pays for it.

### Player controls (the entire control scheme)

- **Two screen buttons, bottom right.** `FOLLOW ME` / `GO TRAIN`, and
  `SEND TO TOWER` / `CALL BACK`. They label themselves from the Mini's actual
  `ActionState`, so the UI cannot lie about what the Mini is doing.
- **Two ProximityPrompts on the plot.** A post by the pit (send to tower) and a
  post by the dojo (upgrade bag, shows the live price).
- Recalling mid-fight is allowed and keeps the coins already earned.

### Mini action states (`ActionState` attribute)

| State | Meaning | Punches? | Locomotion |
|---|---|---|---|
| `Follow` | beside the owner | no | mirrors owner's pose |
| `Training` | at the bag | yes, on arrival | own walk cycle |
| `Ready` | topped up, mooching | no | own walk cycle, slow |
| `Fighting` | in the pit | yes, on arrival | own walk cycle |
| `Returning` | walking home beaten | no | own walk cycle |

---

## 2. ARCHITECTURE

```
src/shared/
  Config/    GameConfig, MiniConfig, EconomyConfig, UpgradeConfig,
             EnemyConfig, MutationConfig
  Net/       Remotes           -- every remote declared; bind() REQUIRES a rate limit
  Types/     Profile, MiniSnapshot, Service
  Util/      Signal, Format, PunchClock, Pool, RigScaler (legacy R6, unused)

src/server/Services/           -- LOAD_ORDER in init.server.luau, deps only upward
  AnalyticsService             funnel events
  DataService                  ProfileStore, schema v3 + migrations
  MiniAvatarService            builds the R15 Mini from HumanoidDescription
  MiniBaseService              the plot: dojo, bag, pit, posts, player spawn
  MiniService                  owns the Mini model + the action state machine
  TrainingService              punch payouts, XP/levels, bag upgrade, publishing
  TowerService                 the pit: floors, enemies, rewards, KO, recall
  MiniCommandService           the ONLY place a player command becomes a state

src/client/Controllers/        -- LOAD_ORDER in init.client.luau
  DebugController              FPS/ping HUD (Studio only)
  MiniController               movement, pose mirroring, punch animation, sound
  MiniEffectsController        level-up burst, growth tween, punch sparks
  MiniStatsController          the card above the Mini's head
  HudController                coin pill (top left)
  CommandController            the two buttons
```

**Server owns all state. Client owns all presentation.** The client never
computes a stat, never reports a hit, never decides a reward.

### The shared punch clock — the single most important design here

`Shared/Util/PunchClock.luau`. The server publishes two attributes on the Mini:
`PunchEpoch` (a `Workspace:GetServerTimeNow()` timestamp) and `AttackRate`.
Everyone then derives punch N as `floor((serverTime - epoch) * rate)`.

- The client animates punch N.
- `TrainingService` pays out for punch N.
- `TowerService` resolves damage for punch N.

Nothing is sent per punch. The fists on screen ARE the hits the server counts,
for as long as the session runs, and a hacked client that throws a thousand
punches a second still earns exactly what the clock says. **Do not replace this
with per-punch remotes.**

### Mini attributes (server → everyone)

`OwnerUserId`, `AppearanceReady`, `ActionState`, `ActionCFrame`, `AttackRate`,
`PunchEpoch`, `Level`, `Power`, `Health`, `MaxHealth`, `Xp`, `XpForLevel`,
`TowerFloor`, `ReadyToFight`, `Growth`.

Coins are deliberately **not** an attribute — they go to the owner alone via the
`CurrencyChanged` remote, because every client can read attributes.

---

## 3. HARD-WON TECHNICAL KNOWLEDGE — READ THIS BEFORE TOUCHING THE MINI

These cost real time to discover. Do not rediscover them.

### 3.1 The rig uses AnimationConstraints, not Motor6Ds

`Players:CreateHumanoidModelFromDescriptionAsync` returns a modern rig whose
joints are `AnimationConstraint`, not `Motor6D`. `MiniController` handles both,
keyed by `part0Name>part1Name` / `attachment0.Parent>attachment1.Parent`.

### 3.2 Joint rotation directions are the opposite of the obvious guess

On this rig, **positive X rotation swings a limb FORWARD** for shoulders and
elbows (knees therefore bend negative). The first implementation punched
backwards for exactly this reason.

### 3.3 `CFrame.Angles(x, y, z)` rolls the arm; it does not aim it

`CFrame.Angles` applies `Rx * Ry * Rz`, so a yaw component gets applied in the
arm's own frame *after* the lift — which rolls the arm around its length instead
of bringing the fist to the centre line. To aim a punch inward you must yaw in
torso space FIRST: `CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)`.

### 3.4 Rigs stream in over several frames

Collecting the joint map once, on `ChildAdded`, caught as few as 7 of 15 joints
and silently dropped a whole arm. Both joint maps (the Mini's and the owner's
character's) are rebuilt whenever a new joint appears. Any new code that walks
the rig at spawn must do the same.

### 3.5 Everything the Mini reaches for is measured in Mini-lengths

The punch was measured against the bag at scale 0.35 (fist lands within 0.03
studs of the surface). When the Mini grows, its arms grow, so **every stand-off
distance must scale with `MiniService.getGrowth(player)`** — the bag stand-off
and the pit gap both do. Add a third and it must too, or a grown Mini punches
through what it is hitting.

### 3.6 The server does not know where the Mini is

The client simulates the Mini's position; the server's copy never moves. The
server instead reasons from **the last place it told the Mini to go**
(`MiniService`'s internal `currentAnchor`). That is how walk-in times are
computed from real distances without trusting the client.

### 3.7 Studio pauses rendering when its window is hidden

`RunService.PreRender` stops firing and **TweenService stops advancing**. Since
the Mini's movement lives in `PreRender`, a background Studio window shows a Mini
frozen at spawn while the server happily keeps paying out. This is an artefact of
testing, not a bug — but it means **any visual verification must be done with the
Studio window in the foreground**, and MCP screenshot calls time out when it is
not.

### 3.8 Service start order is a real race

Bases are built during `MiniBaseService.Start`, which runs before the services
that bind behaviour to the props on them. `TrainingService` and `TowerService`
both listen to `MiniBaseService.BaseCreated` *and* sweep already-existing bases
on start. Any new service that binds to base furniture must do both.

Similarly, the base exists before the profile finishes loading, so anything that
needs data (e.g. the upgrade price on the prompt) must also refresh on
`DataService.ProfileLoaded`.

---

## 4. ASSETS IN USE

| Purpose | ID | Notes |
|---|---|---|
| Punch impact sound | `107581892029163` | **Ours**, uploaded by the owner |
| Level-up sound | `7381724959` | PLACEHOLDER, free Creator Store |
| Mini walk cycle | `507777826` | Roblox stock R15 walk |
| Sparks texture | `rbxasset://textures/particles/sparkles_main.dds` | built in |
| Custom punch animation | `128885657069580` | **NOT USED** — see below |

Art (`Dojo`, `Punchingbag`) lives in `ServerStorage.Assets` **in the place file,
not in Rojo**. Rojo owns code; the place owns art. Their dimensions are measured
at boot, never hardcoded.

**On the custom punch animation:** the owner authored one, but the punch that
shipped is procedural (joint writes in `MiniController.trainingPose`), because it
could be measured and tuned until the fist actually landed on the bag. Swapping to
the authored animation is still open — but the stand-off distances would have to
be re-measured against it. Do not swap it in blind.

**Audio cannot be uploaded through the Studio MCP.** The owner imports via
Studio → Asset Manager → Audio, then hands over the ID.

---

## 5. BALANCE — ALL OF IT IS A FIRST GUESS

Everything lives in `MiniConfig`. Nothing here has been tuned against a real
player; it was chosen to make the loop legible.

- Punch: +1 Power, +25 Health, +10 XP, +1 coin (all × bag multiplier)
- Level: XP cost 60 × 1.22^(n-1); pays +120 max health, +60 health, +5 Power
- Growth: +2.5 % size per level, capped at 1.30× (the dojo is a fixed-size set —
  the Mini must not outgrow its own gym; a bigger dojo is a good future upgrade)
- Tower floor N: enemy health 40 × 1.5^(N-1), damage 8 × 1.34^(N-1),
  coins 8 × 1.35^(N-1)
- Bag upgrade: $25 × 1.32^level, +45 % per level
- A fresh Mini wakes at 12 % health so the first session has something to fill

A level-1 Mini dies around floor 5. That felt right; it has not been validated.

---

## 6. WHAT IS NOT DONE

**Immediate next step (already agreed with the owner):**
The punching bag should visibly **break/wear out** as the Mini fills up, so the
"ready" signal is the bag falling apart rather than just the Mini wandering off.
This also opens the door to the missing structural piece below.

**The missing structural piece:** in Grow a Chicken Fighter the feeder holds a
finite, upgradeable food stock (`6/s · 316/360`) that the chicken consumes. That
limit is the tycoon spine — it is why coins have anywhere to go. Our bag is
infinite. Training self-limits only because health caps out. Give the bag a
stock/wear system and the economy gets its backbone.

**Not started:** mutations and visual variants (the Collection hook), the Pit as a
social/PvP space, offline training, Ascension, saving verified against a live
DataStore, sound design beyond two effects, any shop UI, mobile layout testing,
performance testing with 20+ Minis.

**Known rough edges:**
- `[MiniController] pose mirror: 0 matching joints` appears occasionally in the
  log right after the appearance swap. The dirty-rebuild recovers it, and the
  print does not repeat — but it is worth watching.
- The level-up effect and the growth tween are verified as *code that runs and
  creates the right instances*, not as something anybody has watched move.
- `MiniService.v03.backup` is dead weight in `src/server/Services/` and should be
  deleted.

---

## 7. REPO AND WORKFLOW

- GitHub: `https://github.com/BADYHADY/Grow-a-mini`
- Local: `C:\Users\elias\OneDrive\Dokument\Roblox Grow a mini me fighter`
- Rojo 7.7.0, typically already serving on `127.0.0.1:34872`. If `rojo serve`
  reports "address already in use", a server is already running — do not start a
  second one.
- Studio MCP is connected (instance name "Build mini") and can read the game
  tree, run Luau in Edit/Server/Client contexts, and start/stop play tests.

**Everything since `be8d85e` (V0.4A.1) is UNCOMMITTED.** The V0.4B–V0.6 work —
training, the tower, the loop, the buttons, growth — is all in the working tree.
Committing it in coherent slices is a good first act.

### Working agreements

- **Talk to the owner in Swedish. All code, comments, variable names and in-game
  text in English.**
- Ship small, testable slices. Do not rewrite twenty systems because one broke:
  reproduce → find root cause → smallest safe patch → test → regression test.
- The owner playtests and sends screenshots, video and Output logs. Use them.
- Verify claims by measuring in-game rather than asserting. Most of §3 above was
  found by measuring things that "obviously" worked.

### The decision hierarchy

1. Is it fun? 2. Is it immediately understandable? 3. Does it strengthen "my
avatar is my fighter"? 4. Does it improve the first session? 5. Retention?
6. Social? 7. Shareable? 8. Monetisation without damaging 1–7? 9. Maintainable?
10. Worth the development time?

Classify every new idea as CORE / HIGH VALUE / LATER / BAD IDEA, and protect the
sentence: **grow yourself into an insane Mini fighter.**
