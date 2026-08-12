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

-- The impact sound belongs to the bag, not the listener: parenting it to the
-- part makes it positional for free, so you only hear a Mini training when you
-- are standing at that plot.
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

if speaker and not state.punchSound then
local sound = Instance.new("Sound")
sound.Name = "MiniPunch"
sound.SoundId = TRAINING.PunchSoundId
sound.Volume = TRAINING.PunchSoundVolume
sound.RollOffMode = Enum.RollOffMode.InverseTapered
sound.RollOffMinDistance = TRAINING.PunchSoundMinDistance
sound.RollOffMaxDistance = TRAINING.PunchSoundMaxDistance
sound.Parent = speaker

state.punchSound = sound
end

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

resolveBag(state)

state.bagAngularVelocity +=
TRAINING.BagImpulseRadiansPerSecond

if state.punchSound then
-- Identical samples in a row read as a machine gun.
state.punchSound.PlaybackSpeed =
1
+ (math.random() * 2 - 1)
* TRAINING.PunchSoundPitchJitter

state.punchSound.TimePosition = 0
state.punchSound:Play()

Effects.punchImpact(
state.punchSound.Parent,
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


local function targetPosition(
state: MiniState,
root: BasePart,
character: Model
): Vector3

local raw =
root.CFrame:PointToWorldSpace(
Vector3.new(
SETTINGS.SideOffsetStuds,
0,
SETTINGS.BackOffsetStuds
)
)

raycastParams.FilterDescendantsInstances = {
character,
minisFolder,
}


local origin =
Vector3.new(
raw.X,
raw.Y
+ SETTINGS.GroundProbeHeightStuds,
raw.Z
)


local hit =
Workspace:Raycast(
origin,

Vector3.new(
0,
-SETTINGS.GroundProbeDistanceStuds,
0
),

raycastParams
)


if hit then
return Vector3.new(
raw.X,

hit.Position.Y
+ state.groundOffset,

raw.Z
)
end


return Vector3.new(
raw.X,
state.position.Y,
raw.Z
)
end


-- The server publishes what the Mini is doing as attributes on the model.
-- States in which the Mini is throwing punches once it has arrived: at the bag,
-- or at whatever the tower has put in front of it.
local PUNCHING_STATES = {
Training = true,
Fighting = true,
}

-- How close counts as having passed a waypoint. Loose on purpose: waypoints are
-- corners to round, not marks to hit, and the arrival easing would have the Mini
-- braking to a crawl at every one of them.
local ROUTE_WAYPOINT_RADIUS = 1.6


-- The floor the Mini is allowed to roam, measured off the real dojo by
-- MiniBaseService and published on the base. Falls back to a small circle
-- around the training spot for a base built before that existed.
local function wanderArea(state: MiniState, spot: CFrame): (Vector3, Vector2)
local bases = Workspace:FindFirstChild("MiniBases")
local base = bases and bases:FindFirstChild(`MiniBase_{state.owner.UserId}`)

local centre = base and base:GetAttribute("WanderCenter")
local extents = base and base:GetAttribute("WanderExtents")

if typeof(centre) == "Vector3" and typeof(extents) == "Vector2" then
-- The floor's own Y is the model's centre, not its surface. The training
-- spot is already on the surface, so take the height from there.
return Vector3.new(centre.X, spot.Position.Y, centre.Z), extents
end

return spot.Position, Vector2.new(WANDER.RadiusStuds, WANDER.RadiusStuds)
end


-- While it is topped up the Mini has nowhere it needs to be, so it goes and
-- lives its own life on the dojo floor: crosses the mat, stops, looks around,
-- picks somewhere else. That aimless pottering is the "ready" signal -- no popup
-- tells the player anything, they just see it stop working and start mooching.
--
-- Returns where it is heading, and what to face when it gets there. A facing of
-- nil means "look where you are walking".
local function wanderTarget(
state: MiniState,
spot: CFrame
): (Vector3, Vector3?)

local now = os.clock()
local arrived =
state.wanderTarget ~= nil
and (horizontal(state.position - state.wanderTarget)).Magnitude
< WANDER.ArriveRadiusStuds

-- Standing at the last spot with time still on the clock: this is the pause,
-- and the Mini spends it turning to look at things rather than freezing
-- mid-floor like a mannequin.
if state.wanderTarget and (now < state.wanderPauseUntil or not arrived) then
if arrived and now >= state.wanderLookUntil then
local angle = math.random() * math.pi * 2

state.wanderLook = Vector3.new(math.cos(angle), 0, math.sin(angle))
state.wanderLookUntil = now
+ WANDER.LookSecondsMin
+ math.random() * (WANDER.LookSecondsMax - WANDER.LookSecondsMin)
end

return state.wanderTarget, if arrived then state.wanderLook else nil
end


local centre, extents = wanderArea(state, spot)

-- Somewhere else on the mat, and deliberately not somewhere near: a Mini that
-- shuffles six inches at a time reads as broken rather than as restless.
local target

for _ = 1, 6 do
local candidate = centre
+ Vector3.new(
(math.random() * 2 - 1) * extents.X,
0,
(math.random() * 2 - 1) * extents.Y
)

target = candidate

if not state.wanderTarget
or (horizontal(candidate - state.wanderTarget)).Magnitude
> WANDER.MinTripStuds
then
break
end
end

state.wanderTarget = target
state.wanderPauseUntil = now
+ WANDER.PauseSecondsMin
+ math.random() * (WANDER.PauseSecondsMax - WANDER.PauseSecondsMin)
-- Cleared so the Mini picks a fresh thing to look at once it arrives.
state.wanderLookUntil = 0

return state.wanderTarget, nil
end


-- Anything other than Follow means the Mini has somewhere of its own to be, and
-- stops tracking the owner.
local function actionTarget(
state: MiniState
): (Vector3?, Vector3?)

local model = state.model
local action = model:GetAttribute("ActionState")

if action == nil or action == "Follow" then
return nil, nil
end


local spot = model:GetAttribute("ActionCFrame")

if typeof(spot) ~= "CFrame" then
return nil, nil
end


if action == "Ready" then
local target, facing = wanderTarget(state, spot)

-- Facing is nil while it is walking, so it looks where it is going; once it
-- arrives the wander hands us something for it to turn and look at.
return target + Vector3.new(0, state.groundOffset, 0), facing
end


state.wanderTarget = nil


-- The map is a dojo platform, a bridge and an arena plate strung out over a
-- hundred studs, so the server sends a ROUTE rather than a destination: walk
-- to point 1, then 2, then 3. Without it the Mini walks the straight line
-- from the bag to the Colyseum, which goes through open air.
local count = model:GetAttribute("RouteCount")

-- Any live route means the Mini is on a journey the server planned, however
-- long. That is what holds off the snap-back -- including on the final leg,
-- which is the 24-stud walk in over the sand, and including a one-point
-- route, which is what a failed path falls back to.
state.followingRoute = type(count) == "number" and count > 0

if type(count) == "number" and count > 0 then
-- Restart the route whenever the server issues a new one.
if state.routeSignature ~= `{action}:{count}:{tostring(spot.Position)}` then
state.routeSignature = `{action}:{count}:{tostring(spot.Position)}`
state.routeIndex = 1
end

while state.routeIndex < count do
local leg = model:GetAttribute(`RoutePoint{state.routeIndex}`)

if typeof(leg) ~= "Vector3" then
break
end

-- Waypoints are only markers to pass near, not marks to stand on, so
-- the tolerance is loose. The LAST one is the real spot and is handled
-- by falling out of this loop.
if (horizontal(state.position - leg)).Magnitude > ROUTE_WAYPOINT_RADIUS then
return leg + Vector3.new(0, state.groundOffset, 0), nil
end

state.routeIndex += 1
end
end


-- The server hands us a point ON the floor, while the Mini is positioned by
-- its pivot. Same convention the ground raycast uses.
return spot.Position
+ Vector3.new(0, state.groundOffset, 0),

spot.LookVector
end


local function updateRoot(
state: MiniState,
dt: number
)
local desired, desiredForward =
actionTarget(state)

local training = desired ~= nil


if not desired then
-- Follow: track the owner, as before.
local character =
state.owner.Character

if not character then
return
end


local root =
character:FindFirstChild(
"HumanoidRootPart"
)

if not root
or not root:IsA("BasePart")
then
return
end


desired =
targetPosition(
state,
root,
character
)

desiredForward =
safeUnit(
root.CFrame.LookVector,
state.forward
)
end


local flatCurrent =
horizontal(state.position)

local flatDesired =
horizontal(desired)

local difference =
flatDesired - flatCurrent

local distance =
difference.Magnitude


-- It only starts punching once it has actually arrived at the mark, and only
-- in a state where there is something in front of it to hit.
local action = state.model:GetAttribute("ActionState")

if training
and PUNCHING_STATES[action]
then
if distance <= TRAINING.ArriveRadiusStuds then
state.working = true
end

else
state.working = false
state.impactPending = false
end


-- The snap-back exists for a Mini that has fallen impossibly far behind its
-- owner. It must NOT fire while the Mini is walking a route the server gave
-- it: the map is over a hundred studs end to end, so the trip to the
-- Colyseum is legitimately further than this, and snapping would blink the
-- fighter to the arena instead of letting the player watch it walk there.
if distance >= MiniConfig.TeleportDistanceStuds
and not state.followingRoute
then
state.position = desired
state.velocity = Vector3.zero

else
local desiredVelocity =
Vector3.zero


-- A punching mark is a precise spot; a place to stand about is not.
local stopRadius =
if action == "Ready"
then 0.25
elseif training
then TRAINING.SpotToleranceStuds
else SETTINGS.StopRadiusStuds


if distance
> stopRadius
then
local direction =
difference.Unit


local arrival =
math.clamp(
(
distance
- stopRadius
)
/ SETTINGS.ArrivalRadiusStuds,

0,
1
)


arrival =
arrival
* arrival
* (3 - 2 * arrival)


local catchMultiplier = 1


if distance
> SETTINGS.CatchUpStartStuds
then
catchMultiplier =
math.clamp(
distance
/ SETTINGS.CatchUpStartStuds,

1,
SETTINGS.MaxSpeedMultiplier
)
end


-- Three speeds, and the difference is the whole point: an idle Mini ambles,
-- a Mini with somewhere to be jogs there, and a Mini keeping up with a
-- sprinting player moves at whatever that takes.
local topSpeed =
if action == "Ready"
then WANDER.SpeedStuds
elseif training
then WANDER.TravelSpeedStuds
else MiniConfig.MoveSpeed


desiredVelocity =
direction
* topSpeed
* arrival
* catchMultiplier
end


local acceleration =
if desiredVelocity.Magnitude
> state.velocity.Magnitude
then
SETTINGS.AccelerationStudsPerSecond2
else
SETTINGS.DecelerationStudsPerSecond2


state.velocity =
moveTowards(
state.velocity,
desiredVelocity,
acceleration * dt
)


local travel =
state.velocity * dt


if distance > 0
and travel.Magnitude > distance
then
state.position =
Vector3.new(
desired.X,
state.position.Y,
desired.Z
)

state.velocity =
Vector3.zero

else
state.position += travel
end


local yAlpha =
expAlpha(
SETTINGS.VerticalResponsiveness,
dt
)


state.position =
Vector3.new(
state.position.X,

state.position.Y
+ (
desired.Y
- state.position.Y
)
* yAlpha,

state.position.Z
)
end


-- Facing comes from the REAL avatar when following, or from the action spot
-- when training. No fake wobble, lean, bob or procedural turning either way.
-- With no facing handed to us -- wandering, or walking home -- the Mini looks
-- where it is going, and holds its last heading once it stops.
if not desiredForward
and state.velocity.Magnitude > 0.15
then
desiredForward = state.velocity
end


desiredForward =
safeUnit(
desiredForward or state.forward,
state.forward
)


state.forward =
safeUnit(
state.forward:Lerp(
desiredForward,

expAlpha(
SETTINGS.TurnResponsiveness,
dt
)
),

state.forward
)


local pivot =
CFrame.lookAt(
state.position,
state.position + state.forward
)


state.model:PivotTo(pivot)
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
local action = state.model:GetAttribute("ActionState")

-- Anything but following its owner is the Mini going somewhere under its
-- own steam: to the bag, out to the pit, home again, or just about. All of
-- it needs its own legs, because the owner may well be standing still.
local onOwnBusiness =
action ~= nil
and action ~= "Follow"
and not state.working

-- Hysteresis on the speed, so a Mini hovering at the threshold does not
-- strobe between walking and standing.
local speed = horizontal(state.velocity).Magnitude

if onOwnBusiness and speed > WANDER.AnimateAboveStuds then
setWalking(state, true, speed)
elseif not onOwnBusiness or speed < WANDER.AnimateBelowStuds then
setWalking(state, false, speed)
end


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
end
end)


RunService.PreRender:Connect(function(dt)
for _, state in states do
updateRoot(
state,
dt
)
end
end)

end


return MiniController