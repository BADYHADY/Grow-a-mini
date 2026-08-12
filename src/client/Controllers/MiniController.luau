--!nonstrict
-- Mini movement presentation.
--
-- The Mini does NOT have a fake procedural walk cycle.
--
-- Its visible body pose is mirrored directly from the owner's real Roblox
-- character every frame. Run, idle, jump, emotes and custom avatar animations
-- therefore naturally flow through to the Mini.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MiniConfig = require(Shared.Config.MiniConfig)
local GameConfig = require(Shared.Config.GameConfig)

local SETTINGS = MiniConfig.Personality
local TRAINING = MiniConfig.Training
local WANDER = MiniConfig.Wander

local MiniController = {}

-- Set in Init from the controller registry: this file knows WHEN a fist lands,
-- the effects controller knows what that should look like.
local Effects


type MiniState = {
model: Model,
owner: Player,

position: Vector3,
velocity: Vector3,
forward: Vector3,
groundOffset: number,

sourceCharacter: Model?,
sourceJoints: { [string]: any },
targetJoints: { [string]: any },

-- Rigs arrive over several frames, so both joint maps are rebuilt whenever a
-- new joint shows up rather than trusted from the first pass.
sourceDirty: boolean,
targetDirty: boolean,
sourceWatch: RBXScriptConnection?,
targetWatch: RBXScriptConnection?,
growthWatch: RBXScriptConnection?,

reportedJointCount: boolean,

-- Training. `working` is the moment the Mini stops being a follower and
-- starts being a fighter: it has reached the spot and is throwing punches.
working: boolean,
-- The punch index the pose is currently playing. -1 means "none yet", so the
-- very first punch still registers as a new one.
punchIndex: number,
impactPending: boolean,

-- Idling around the dojo, and the legs it does that on.
-- Studs per second, straight from Humanoid.Running. See the note where it
-- is used: measuring this from position deltas does not work for a body
-- whose physics the server owns.
runSpeed: number,

wanderTarget: Vector3?,
wanderPauseUntil: number,
-- What it is looking at while it stands about, and for how long.
wanderLook: Vector3?,
wanderLookUntil: number,

-- Progress along the server's route. The signature is what tells us the
-- server issued a NEW route rather than the same one again.
routeIndex: number,
routeSignature: string?,
-- True while there are waypoints still to walk, which is what stops the
-- long-distance snap-back from firing mid-journey.
followingRoute: boolean,
walkTrack: AnimationTrack?,
walkPlaying: boolean,

-- The bag this Mini is hitting, resolved lazily on the first punch.
punchSound: Sound?,
bagModel: Model?,
bagRestPivot: CFrame?,
bagAnchor: Vector3?,
bagAngle: number,
bagAngularVelocity: number,
-- Wear, 0 = pristine, 1 = collapsed. Smoothed locally toward the server's
-- Condition attribute so the bag sags as it is hit and straightens back up
-- over a few seconds once the Mini walks away.
bagWear: number,
bagTintStep: number,
bagPartColors: { [BasePart]: Color3 }?,
bagLeanAxis: Vector3?,
-- The part of the bag that reads as the point of contact.
bagSpeaker: BasePart?,

-- The opponent standing in front of it, and how hard it was last hit. The
-- enemy model is built and owned by the server, but nothing on the server ever
-- moves it -- so knocking it back is presentation, done here, driven off the
-- same punch clock that decides the damage.
enemyModel: Model?,
enemyRestPivot: CFrame?,
enemyRecoil: number,
}


local minisFolder: Folder
local states: { [Model]: MiniState } = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType =
Enum.RaycastFilterType.Exclude

raycastParams.IgnoreWater = true


local function horizontal(vector: Vector3): Vector3
return Vector3.new(
vector.X,
0,
vector.Z
)
end


local function safeUnit(
vector: Vector3,
fallback: Vector3
): Vector3

local flat = horizontal(vector)

if flat.Magnitude < 0.001 then
return fallback
end

return flat.Unit
end


local function expAlpha(
response: number,
dt: number
): number

return 1 - math.exp(-response * dt)
end


local function moveTowards(
current: Vector3,
target: Vector3,
maxDelta: number
): Vector3

local delta = target - current
local distance = delta.Magnitude

if distance <= maxDelta
or distance < 0.0001
then
return target
end

return current + delta.Unit * maxDelta
end


-- ============================================================
-- JOINT MIRRORING
--
-- Supports BOTH Roblox joint generations:
--
-- legacy Motor6D
-- modern AnimationConstraint
-- ============================================================

local function isPoseJoint(
instance: Instance
): boolean

return instance:IsA("Motor6D")
or instance:IsA("AnimationConstraint")
end


local function jointKey(
joint: Instance
): string?

if joint:IsA("Motor6D") then
local part0 = joint.Part0
local part1 = joint.Part1

if not part0 or not part1 then
return nil
end

return part0.Name .. ">" .. part1.Name
end


if joint:IsA("AnimationConstraint") then
local attachment0 = joint.Attachment0
local attachment1 = joint.Attachment1

if not attachment0
or not attachment1
or not attachment0.Parent
or not attachment1.Parent
then
return nil
end

return attachment0.Parent.Name
.. ">"
.. attachment1.Parent.Name
end


return nil
end


local function collectPoseJoints(
model: Model
): { [string]: any }

local result = {}

for _, descendant in model:GetDescendants() do
if not isPoseJoint(descendant) then
continue
end

local key = jointKey(descendant)

if key then
result[key] = descendant
end
end

return result
end


local function readTransform(
joint: Instance
): CFrame

if joint:IsA("Motor6D") then
return joint.Transform
end

if joint:IsA("AnimationConstraint") then
return joint.Transform
end

return CFrame.identity
end


local function writeTransform(
joint: Instance,
transform: CFrame
)
if joint:IsA("Motor6D") then
joint.Transform = transform
return
end

if joint:IsA("AnimationConstraint") then
joint.Transform = transform
end
end


local function rebuildSourceJoints(
state: MiniState,
character: Model
)
state.sourceCharacter = character
state.sourceJoints =
collectPoseJoints(character)

state.reportedJointCount = false

if state.sourceWatch then
state.sourceWatch:Disconnect()
end

-- A character is not fully assembled the instant it appears; limbs and their
-- joints keep arriving for several frames. Collecting once caught as few as
-- seven of the fifteen joints, which silently dropped a whole arm out of the
-- pose.
state.sourceWatch =
character.DescendantAdded:Connect(function(descendant)
if isPoseJoint(descendant) then
state.sourceDirty = true
end
end)

state.sourceDirty = false
end


-- Same race on the Mini's own rig, and with the same consequence: a missing
-- shoulder means an arm that never punches.
local function refreshTargetJoints(state: MiniState)
if not state.targetDirty then
return
end

state.targetDirty = false
state.targetJoints = collectPoseJoints(state.model)
end


local function mirrorPose(state: MiniState)
local character =
state.owner.Character

if not character then
return
end

refreshTargetJoints(state)

if state.sourceCharacter ~= character
or state.sourceDirty
then
rebuildSourceJoints(
state,
character
)
end


local matched = 0

for key, sourceJoint in state.sourceJoints do
local targetJoint =
state.targetJoints[key]

if targetJoint then
writeTransform(
targetJoint,
readTransform(sourceJoint)
)

matched += 1
end
end


if GameConfig.DebugLogging
and not state.reportedJointCount
then
state.reportedJointCount = true

print(
`[MiniController] pose mirror {state.owner.Name}: {matched} matching joints`
)
end
end


-- ============================================================
-- TRAINING: PUNCHING THE BAG
--
-- The server says WHAT the Mini is doing (ActionState) and HOW FAST
-- (AttackRate). The punch itself is played out locally on every client, so the
-- rhythm stays smooth and costs nothing on the wire.
--
-- While punching, the owner's pose is deliberately NOT mirrored: the Mini is
-- doing its own job now, which is the entire point of the training loop.
-- ============================================================

local RIGHT_ANGLE = math.pi * 0.5


local function setJoint(
state: MiniState,
key: string,
transform: CFrame
)
local joint = state.targetJoints[key]

if joint then
writeTransform(joint, transform)
end
end


-- 0 at guard, 1 at full extension, slightly negative during the wind-up.
local function punchExtension(t: number): number
local windup = TRAINING.WindupFraction
local strike = TRAINING.StrikeFraction

if t < windup then
return -0.22 * math.sin((t / windup) * math.pi)
end

if t < windup + strike then
return math.sin(((t - windup) / strike) * RIGHT_ANGLE)
end

-- Recovery: ease back to guard over whatever is left of the period. Much
-- slower than the strike, which is what sells the snap.
local remaining = 1 - windup - strike
local u = (t - windup - strike) / remaining

return (1 - u) * (1 - u)
end


-- How far back a hit shoves the opponent, and how fast it recovers. Small: a
-- fighter that is knocked halfway across the pit by a jab reads as a physics
-- glitch, and the Mini has to still be within arm's reach for the next one.
-- The punch sound hangs on the FIGHTER, not on what it is hitting, so it is
-- heard wherever the Mini happens to be swinging. Parented to a part, so it
-- stays positional for free: you hear a Mini working only when you are standing
-- at its plot.
local function punchSpeaker(state: MiniState): Sound?
if state.punchSound and state.punchSound.Parent then
return state.punchSound
end

local host = state.model:FindFirstChild("UpperTorso") or state.model.PrimaryPart

if not host then
return nil
end

local sound = Instance.new("Sound")
sound.Name = "MiniPunch"
sound.SoundId = TRAINING.PunchSoundId
sound.Volume = TRAINING.PunchSoundVolume
sound.RollOffMode = Enum.RollOffMode.InverseTapered
sound.RollOffMinDistance = TRAINING.PunchSoundMinDistance
sound.RollOffMaxDistance = TRAINING.PunchSoundMaxDistance
sound.Parent = host

state.punchSound = sound

return sound
end


local ENEMY_RECOIL_STUDS = 0.35
local ENEMY_RECOIL_DECAY_PER_SECOND = 9

-- The opponent TowerService stood up for the current floor.
--
-- It is a sibling of the bases rather than a child of this player's base --
-- TowerService parents it straight into the MiniBases folder -- so it is found
-- by the name the server gives it. Re-resolved every time it dies, because a
-- cleared floor destroys its enemy and builds the next one in its place.
local function resolveEnemy(state: MiniState): Model?
if state.enemyModel and state.enemyModel.Parent then
return state.enemyModel
end

state.enemyModel = nil
state.enemyRestPivot = nil
state.enemyRecoil = 0

local bases = Workspace:FindFirstChild("MiniBases")
local enemy = bases and bases:FindFirstChild(`TowerEnemy_{state.owner.UserId}`)

if not enemy or not enemy:IsA("Model") then
return nil
end

state.enemyModel = enemy
state.enemyRestPivot = enemy:GetPivot()

return enemy
end


-- Settles a knocked-back opponent to where it was standing. Stepped every
-- frame, like the bag, so recovery is smooth rather than a snap on the next
-- punch.
local function updateEnemy(state: MiniState, dt: number)
local model = state.enemyModel
local rest = state.enemyRestPivot

if not model or not rest then
return
end

if not model.Parent then
state.enemyModel = nil
state.enemyRestPivot = nil
state.enemyRecoil = 0
return
end

if state.enemyRecoil <= 0.001 then
return
end

state.enemyRecoil = math.max(
0,
state.enemyRecoil - state.enemyRecoil * ENEMY_RECOIL_DECAY_PER_SECOND * dt
)

-- Straight back along the line from the Mini, so it is shoved away from the
-- punch rather than in some fixed world direction.
local root = state.model.PrimaryPart
local away = if root
then horizontal(rest.Position - root.Position)
else Vector3.zero

if away.Magnitude < 0.01 then
return
end

model:PivotTo(rest + away.Unit * (state.enemyRecoil * ENEMY_RECOIL_STUDS))
end


-- The bag lives on the owner's base, which is built by MiniBaseService under
-- these names. Resolved lazily: the base may still be replicating when the Mini
-- first arrives.
local function resolveBag(state: MiniState)
if state.bagModel and state.bagModel.Parent then
return
end

local bases = Workspace:FindFirstChild("MiniBases")

if not bases then
return
end

local base = bases:FindFirstChild(
`MiniBase_{state.owner.UserId}`
)

local bag = base and base:FindFirstChild("Punchingbag")
local body = bag and bag:FindFirstChild("Bag_modle")

if not body or not body:IsA("Model") then
return
end

local boxCFrame, boxSize = body:GetBoundingBox()

state.bagModel = body
state.bagRestPivot = body:GetPivot()

-- Remembered before anything tints them, so a repaired bag goes back to the
-- colour the artist gave it rather than to a guess.
local colors: { [BasePart]: Color3 } = {}

for _, descendant in body:GetDescendants() do
if descendant:IsA("BasePart") then
colors[descendant] = descendant.Color
end
end

state.bagPartColors = colors
state.bagTintStep = 0

-- Which part of the bag reads as the point of contact, for the impact effect.
local speaker

for _, descendant in body:GetDescendants() do
if descendant:IsA("BasePart") then
speaker = speaker or descendant

if descendant.Name:lower():find("bagbody") then
speaker = descendant
break
end
end
end

state.bagSpeaker = speaker

-- The impact SOUND is no longer created here. It used to be parented to the
-- bag, which meant a Mini fighting in the Colyseum played its punch sound and
-- spawned its impact effect back at the dojo, thirty studs away -- the fight
-- was silent at the point of contact. It now hangs on the Mini itself and
-- travels with it; see punchSpeaker.

-- The bag swings from where the chains hold it, not from its middle.
state.bagAnchor = Vector3.new(
boxCFrame.Position.X,
boxCFrame.Position.Y + boxSize.Y * 0.5,
boxCFrame.Position.Z
)
end


local function updateBag(
state: MiniState,
dt: number
)
local model = state.bagModel
local rest = state.bagRestPivot
local anchor = state.bagAnchor

if not model or not rest or not anchor then
return
end

if not model.Parent then
state.bagModel = nil
return
end


-- Wear is the server's number; the client only smooths it. Damage lands
-- fast so a punch reads as having cost something, and repairs slowly so a
-- bag that gave out stays visibly broken long enough to be the signal that
-- the Mini is done.
local WEAR = TRAINING.Wear
local parent = model.Parent
local condition = parent and parent:GetAttribute("Condition")
local known = if type(condition) == "number" then condition else 1
local targetWear = 1 - math.clamp(known, 0, 1)
local wearRate = if targetWear > state.bagWear then 9 else 1 / WEAR.RepairSeconds

state.bagWear += (targetWear - state.bagWear)
* math.min(1, dt * wearRate)

if state.bagWear < 0.002 then
state.bagWear = 0
end

-- Colour is only rewritten when the wear crosses a step. Writing Color on
-- every bag part every frame costs real time and looks identical.
local tintStep = math.floor(state.bagWear * WEAR.TintSteps + 0.5)

if tintStep ~= state.bagTintStep and state.bagPartColors then
state.bagTintStep = tintStep

local blend = tintStep / WEAR.TintSteps

for part, original in state.bagPartColors do
if part.Parent then
part.Color = original:Lerp(WEAR.WornTint, blend)
end
end
end

-- Damped spring, in radians about the mount. Cheap, and it settles instead
-- of stopping dead like a tween would.
local acceleration =
-TRAINING.BagSwingStiffness * state.bagAngle
- TRAINING.BagSwingDamping * state.bagAngularVelocity

state.bagAngularVelocity += acceleration * dt

state.bagAngle = math.clamp(
state.bagAngle + state.bagAngularVelocity * dt,
-TRAINING.MaxBagSwingRadians,
TRAINING.MaxBagSwingRadians
)


local settled = math.abs(state.bagAngle) < TRAINING.BagRestEpsilon
and math.abs(state.bagAngularVelocity) < TRAINING.BagRestEpsilon

if settled then
state.bagAngle = 0
state.bagAngularVelocity = 0

-- Nothing swinging and nothing worn: leave the model alone entirely.
if state.bagWear == 0 then
if state.bagLeanAxis then
state.bagLeanAxis = nil
model:PivotTo(rest)
end

return
end
end


-- Tip the bag AWAY from the Mini: rotate about the horizontal axis that
-- sends the hanging end along the punch direction. A worn bag keeps leaning
-- that way and sags off its mount once the swing has died down, so it hangs
-- broken in the direction it was being beaten.
local axis = state.forward:Cross(Vector3.yAxis)

if axis.Magnitude >= 0.001 then
state.bagLeanAxis = axis.Unit
end

local lean = state.bagLeanAxis

if not lean then
return
end

local angle = state.bagAngle + state.bagWear * WEAR.MaxLeanRadians
local sag = Vector3.new(0, -state.bagWear * WEAR.MaxSagStuds, 0)

model:PivotTo(
CFrame.new(anchor + sag)
* CFrame.fromAxisAngle(lean, angle)
* CFrame.new(-anchor)
* rest
)
end


local function attackPeriod(state: MiniState): number
local rate = state.model:GetAttribute("AttackRate")

if type(rate) ~= "number" or rate <= 0 then
rate = MiniConfig.BaseStats.AttacksPerSecond
end

return 1 / rate
end


local function trainingPose(state: MiniState)
refreshTargetJoints(state)

local period = attackPeriod(state)

-- Punches are counted off the SERVER's clock, not a local timer. The server
-- pays out Power from the same epoch and rate, so the fists on screen and the
-- number above the Mini's head can never drift apart -- and nothing has to be
-- sent per punch to keep them together.
local epoch = state.model:GetAttribute("PunchEpoch")
local elapsed =
if type(epoch) == "number"
then Workspace:GetServerTimeNow() - epoch
else 0

-- Still walking in: hold the guard, do not throw anything yet.
local ready = elapsed >= 0

local total = if ready then elapsed / period else 0
local index = math.floor(total)
local t = if ready then total - index else 0


if index ~= state.punchIndex then
state.punchIndex = index
state.impactPending = ready
end


local extension = if ready then punchExtension(t) else 0


-- The fist lands at the end of the strike, not at the top of the cycle.
if state.impactPending
and t >= TRAINING.WindupFraction + TRAINING.StrikeFraction
then
state.impactPending = false

-- A punch lands on whatever the Mini is standing in front of: the bag at
-- home, the opponent in the Colyseum. Both get shoved, and the impact is
-- drawn and heard at the point of contact rather than always at the bag.
local target: BasePart? = nil

if state.model:GetAttribute("ActionState") == "Fighting" then
local enemy = resolveEnemy(state)

if enemy then
state.enemyRecoil = 1

target = enemy.PrimaryPart or enemy:FindFirstChildWhichIsA("BasePart")
end
else
resolveBag(state)

state.bagAngularVelocity +=
TRAINING.BagImpulseRadiansPerSecond

target = state.bagSpeaker
end

if punchSpeaker(state) then
-- Identical samples in a row read as a machine gun.
state.punchSound.PlaybackSpeed =
1
+ (math.random() * 2 - 1)
* TRAINING.PunchSoundPitchJitter

state.punchSound.TimePosition = 0
state.punchSound:Play()
end

if target then
Effects.punchImpact(
target,
state.model:GetScale() / MiniConfig.Scale.Overall
)
end
end


-- Alternate fists so the Mini reads as working a combination rather than
-- twitching one arm.
local rightLeads = state.punchIndex % 2 == 0

local workingSide = if rightLeads then "Right" else "Left"
local guardSide = if rightLeads then "Left" else "Right"

local reach = math.max(extension, 0)


local guardShoulder = math.rad(TRAINING.GuardShoulderDegrees)
local guardElbow = math.rad(TRAINING.GuardElbowDegrees)

local workingShoulder =
guardShoulder
+ (math.rad(TRAINING.PunchShoulderDegrees) - guardShoulder)
* extension

local workingElbow =
guardElbow
+ (math.rad(TRAINING.PunchElbowDegrees) - guardElbow)
* extension


-- Positive X on this rig's shoulder and elbow swings the limb FORWARD.
-- Measured on the real R15 constraint rig, not assumed.
local inward =
math.rad(TRAINING.PunchInwardDegrees)
* reach
* (if rightLeads then 1 else -1)

-- Yaw FIRST, in torso space, then lift. The other order rolls the arm
-- around its own length instead of bringing the fist to the centre line.
setJoint(
state,
`UpperTorso>{workingSide}UpperArm`,
CFrame.Angles(0, inward, 0)
* CFrame.Angles(workingShoulder, 0, 0)
)

setJoint(
state,
`{workingSide}UpperArm>{workingSide}LowerArm`,
CFrame.Angles(workingElbow, 0, 0)
)

setJoint(
state,
`UpperTorso>{guardSide}UpperArm`,
CFrame.Angles(guardShoulder, 0, 0)
)

setJoint(
state,
`{guardSide}UpperArm>{guardSide}LowerArm`,
CFrame.Angles(guardElbow, 0, 0)
)


-- Anything the pose does not drive has to be cleared, or it keeps whatever
-- the owner's animation last wrote and the Mini punches with a bent wrist.
setJoint(state, "RightLowerArm>RightHand", CFrame.identity)
setJoint(state, "LeftLowerArm>LeftHand", CFrame.identity)
setJoint(state, "LeftLowerLeg>LeftFoot", CFrame.identity)
setJoint(state, "RightLowerLeg>RightFoot", CFrame.identity)
setJoint(state, "UpperTorso>Head", CFrame.identity)


-- The punch comes from the body, not the shoulder.
local twist =
math.rad(TRAINING.TorsoTwistDegrees)
* reach
* (if rightLeads then -1 else 1)

setJoint(
state,
"LowerTorso>UpperTorso",
CFrame.Angles(0, twist, 0)
)


-- A boxer's stance, plus a small drop into each punch.
local stance = math.rad(TRAINING.StanceLegDegrees)
local knee = math.rad(TRAINING.KneeBendDegrees)

-- Lead foot forward, back foot planted, both knees softly bent. Same axis
-- convention as the arms: positive is forward, so the knees bend negative.
setJoint(
state,
"LowerTorso>LeftUpperLeg",
CFrame.Angles(stance, 0, 0)
)

setJoint(
state,
"LowerTorso>RightUpperLeg",
CFrame.Angles(-stance, 0, 0)
)

setJoint(
state,
"LeftUpperLeg>LeftLowerLeg",
CFrame.Angles(-knee, 0, 0)
)

setJoint(
state,
"RightUpperLeg>RightLowerLeg",
CFrame.Angles(-knee, 0, 0)
)


setJoint(
state,
"HumanoidRootPart>LowerTorso",
CFrame.new(
0,
-TRAINING.BobHeightStuds * reach,
0
)
)
end


-- ============================================================
-- SELF-DRIVEN LOCOMOTION
--
-- Mirroring the owner is right while the Mini is a companion. It is wrong the
-- moment the Mini walks somewhere the owner is not walking: a standing player
-- would have their Mini gliding across the plot in an idle pose.
--
-- So when the Mini is moving on its own business it plays a walk cycle on its
-- OWN Animator instead, and goes back to mirroring the instant it stops.
-- ============================================================

local function walkTrack(state: MiniState): AnimationTrack?
if state.walkTrack then
return state.walkTrack
end

local humanoid = state.model:FindFirstChildOfClass("Humanoid")

if not humanoid then
return nil
end

local animator = humanoid:FindFirstChildOfClass("Animator")

if not animator then
animator = Instance.new("Animator")
animator.Parent = humanoid
end

local animation = Instance.new("Animation")
animation.AnimationId = WANDER.WalkAnimationId

local ok, track = pcall(function()
return animator:LoadAnimation(animation)
end)

if not ok or not track then
-- Losing the walk cycle is a cosmetic problem, not a gameplay one: the Mini
-- still gets where it is going.
return nil
end

track.Looped = true
track.Priority = Enum.AnimationPriority.Movement

state.walkTrack = track
return track
end


local function setWalking(
state: MiniState,
walking: boolean,
speed: number
)
local track = walkTrack(state)

if not track then
return
end

if walking then
-- Match the stride to the ground it is actually covering. The stock cycle
-- is authored for a full-size avatar at 16 studs a second, and the Mini is
-- a third of that size -- so the comparison has to be made in BODY lengths
-- or a tiny fighter looks like it is skating.
local bodyScale = state.model:GetScale() / MiniConfig.Scale.Overall
local equivalent = speed / math.max(0.01, MiniConfig.Scale.Overall * bodyScale)

track:AdjustSpeed(
math.clamp(
(equivalent / 16) * WANDER.WalkAnimationSpeed,
0.35,
2.2
)
)
end

if walking == state.walkPlaying then
return
end

state.walkPlaying = walking

if walking then
track:Play(0.15)
else
track:Stop(0.15)
end
end


-- ============================================================
-- ROOT FOLLOW
-- ============================================================

local function calculateGroundOffset(
model: Model
): number

local pivotY =
model:GetPivot().Position.Y

local lowestY = math.huge

for _, descendant in model:GetDescendants() do
if not descendant:IsA("BasePart") then
continue
end

if descendant:FindFirstAncestorOfClass(
"Accessory"
) then
continue
end

local bottom =
descendant.Position.Y
- descendant.Size.Y * 0.5

lowestY =
math.min(
lowestY,
bottom
)
end

if lowestY == math.huge then
return 1
end

return math.max(
0.1,
pivotY - lowestY
)
end


local function ownerFromMini(
model: Model
): Player?

local userId =
model:GetAttribute("OwnerUserId")

if type(userId) ~= "number" then
return nil
end

return Players:GetPlayerByUserId(
userId
)
end


local function register(
instance: Instance
)
if not instance:IsA("Model") then
return
end

task.defer(function()
if not instance.Parent
or states[instance]
then
return
end

local owner =
ownerFromMini(instance)

if not owner then
return
end

local pivot =
instance:GetPivot()

states[instance] = {
model = instance,
owner = owner,

position = pivot.Position,
velocity = Vector3.zero,

forward = safeUnit(
pivot.LookVector,
Vector3.new(0, 0, -1)
),

groundOffset =
calculateGroundOffset(
instance
),

sourceCharacter = nil,
sourceJoints = {},

targetJoints =
collectPoseJoints(
instance
),

sourceDirty = false,
targetDirty = false,
sourceWatch = nil,

-- A Mini that grew stands taller, so the offset that keeps its feet on the
-- floor has to be measured again -- after the grow animation has finished,
-- not while it is playing.
growthWatch = instance:GetAttributeChangedSignal("Growth"):Connect(
function()
task.delay(0.45, function()
local tracked = states[instance]

if tracked and instance.Parent then
tracked.groundOffset =
calculateGroundOffset(instance)
end
end)
end
),

targetWatch = instance.DescendantAdded:Connect(
function(descendant)
local tracked = states[instance]

if tracked and isPoseJoint(descendant) then
tracked.targetDirty = true
end
end
),

reportedJointCount = false,

working = false,
punchIndex = -1,
impactPending = false,

runSpeed = 0,
wanderTarget = nil,
wanderPauseUntil = 0,
wanderLook = nil,
wanderLookUntil = 0,
routeIndex = 1,
routeSignature = nil,
followingRoute = false,
walkTrack = nil,
walkPlaying = false,

punchSound = nil,
bagModel = nil,
bagWear = 0,
bagTintStep = 0,
bagPartColors = nil,
bagLeanAxis = nil,
bagRestPivot = nil,
bagAnchor = nil,
bagAngle = 0,
bagAngularVelocity = 0,

enemyModel = nil,
enemyRestPivot = nil,
enemyRecoil = 0,
}

if GameConfig.DebugLogging then
print(
`[MiniController] tracking R15 Mini for {owner.Name}`
)
end
end)
end


local function unregister(
instance: Instance
)
if not instance:IsA("Model") then
return
end

local state = states[instance]

if state then
if state.sourceWatch then
state.sourceWatch:Disconnect()
end

if state.targetWatch then
state.targetWatch:Disconnect()
end

if state.growthWatch then
state.growthWatch:Disconnect()
end

-- The sound lives on the bag, which outlives the Mini, so it has to go with
-- the Mini that created it.
if state.punchSound then
state.punchSound:Destroy()
end

if state.walkTrack then
state.walkTrack:Stop(0)
state.walkTrack:Destroy()
end
end

states[instance] = nil
end


-- The states in which there is something in front of the Mini to hit.
local PUNCHING_STATES = {
Training = true,
Fighting = true,
}

-- How close to its mark the Mini has to be before it starts throwing punches.
-- The Humanoid parks within a fraction of a stud of where it was sent, and the
-- punch was measured against the bag with that slack already in it.
--
-- Measured in the arena, the Mini parks 0.87 studs from its mark: three
-- hundredths of a stud inside the old limit of 0.9, with the ENTIRE punch
-- animation on the far side of it. A fighter that stands still through the
-- whole fight because the pathfinder stopped a centimetre short is not a
-- failure worth having, so the margin is real now. Walking away is still
-- unambiguous -- the hysteresis below releases at twice this.
local WORKING_RADIUS_STUDS = 2.0


-- WHERE the Mini is is no longer decided here.
--
-- It is a physical Humanoid, walked by the server with Humanoid:MoveTo along a
-- pathfinding route. The engine owns steering, ground, slopes, acceleration and
-- the walk cycle. Roughly five hundred lines of hand-written locomotion used to
-- live at this spot -- arrival easing, ground raycasts, catch-up speeds, a
-- snap-back for falling behind, wander targets -- and the sum of it was a Mini
-- that slid across the floor rather than walked over it. Deleting it IS the
-- fix; there is no version of that code that beats the engine at its own job.
--
-- What the client still owns is presentation: the punch, the pose, the bag, the
-- sound. All of which need exactly one thing from the body, and that is whether
-- the fighter has arrived at its mark.
local function updateWorking(state: MiniState)
local model = state.model
local action = model:GetAttribute("ActionState")
local spot = model:GetAttribute("ActionCFrame")

if not PUNCHING_STATES[action] or typeof(spot) ~= "CFrame" then
state.working = false
state.impactPending = false
return
end

-- Punching starts on arrival, not on the order. The mark is generous: the
-- Humanoid parks within a fraction of a stud, and the punch itself was
-- measured against the bag with that slack already in it.
local reach = (horizontal(state.position - spot.Position)).Magnitude

if reach <= WORKING_RADIUS_STUDS then
state.working = true
elseif reach > WORKING_RADIUS_STUDS * 2 then
-- Hysteresis: knocked back or shoved off the mark mid-fight is not a
-- reason to stop swinging, but walking away is.
state.working = false
state.impactPending = false
end
end


function MiniController.Init(registry)
Effects = registry.MiniEffectsController

minisFolder =
Workspace:WaitForChild("Minis")


for _, child in minisFolder:GetChildren() do
register(child)
end


minisFolder.ChildAdded:Connect(register)
minisFolder.ChildRemoved:Connect(unregister)
end


function MiniController.Start()

-- Roblox Animator has already written the player's pose when
-- PreSimulation fires, so copy it here.
RunService.PreSimulation:Connect(function(dt)
for _, state in states do
-- Read where the server's Humanoid has actually put the Mini. Everything
-- below -- which way the punch faces, how fast the legs should cycle,
-- which way the bag swings -- is derived from the real body rather than
-- from a prediction of it.
local pivot = state.model:GetPivot()

state.position = pivot.Position
state.forward = safeUnit(horizontal(pivot.LookVector), state.forward)

-- How fast it is walking, read off the body's REPLICATED velocity.
--
-- Two things that do not work here, both tried and measured. Deriving the
-- speed from how far the model moved since the last frame reads zero on
-- most frames, because the server owns this body and its position arrives
-- about twenty times a second while this loop runs every frame -- the walk
-- animation stopped and restarted continuously and so never played.
-- Humanoid.Running, which is what Roblox's own Animate script uses, does
-- not fire on this machine at all: that signal belongs to whoever simulates
-- the Humanoid, and that is the server.
--
-- Assembly velocity does replicate, and measuring it here against a Mini
-- walking at 6.66 studs a second reads 6.66.
local root = state.model.PrimaryPart
local speed = if root
then horizontal(root.AssemblyLinearVelocity).Magnitude
else 0

state.runSpeed = speed

if not state.working and speed > WANDER.AnimateAboveStuds then
setWalking(state, true, speed)
elseif state.working or speed < WANDER.AnimateBelowStuds then
setWalking(state, false, speed)
end


updateWorking(state)

if state.working then
trainingPose(state)

elseif not state.walkPlaying then
-- Standing still, or following: wearing the owner's pose is exactly
-- right, and it is what makes the Mini read as them.
mirrorPose(state)
end

-- Always stepped, so a bag keeps swinging out after the Mini stops
-- rather than freezing mid-arc.
updateBag(state, dt)

-- Same reason: a knocked-back opponent settles back to its mark under
-- its own steam instead of snapping there on the next punch.
updateEnemy(state, dt)
end
end)


-- The Mini's POSITION is no longer ours. It is a physical Humanoid walked by
-- the server with MoveTo, so the engine handles steering, ground, slopes and
-- the walk cycle -- all of which it does better than the hand-written
-- simulation that used to live in a PreRender loop here, and which is why the
-- Mini used to slide instead of walk.
--
-- What is left on the client is what the client should own: the punch, the
-- pose, the bag, the sound. See updateWorking's header.

end


return MiniController